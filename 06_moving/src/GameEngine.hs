{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}

module GameEngine where

import Protolude hiding (Map)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.List.Index as Lst
import qualified Data.Text as Txt
import qualified Data.Text.IO as Txt
import qualified Data.Text.Encoding as TxtE
import qualified Data.Aeson.Text.Extended as Ae
import qualified Data.ByteString.Lazy as BSL
import qualified Codec.Compression.BZip as Bz
import qualified System.Random as Rnd
import           Control.Lens (_1, (^.), (.~), (%~))
import qualified Control.Arrow as Ar
import           Control.Concurrent.STM (atomically, readTVar, newTVar, modifyTVar', TVar)

import           GameCore
import qualified GameHost as Host
import           GameHost (conSendData, conReceiveText)
import qualified Entities as E
import qualified EntityType as E


runGame :: IO ()
runGame = Host.runHost manageConnection

      
manageConnection :: Host.Connection -> IO ()
manageConnection conn = do
  initCmd <- conn ^. conReceiveText 

  case parseCommand initCmd of
    Just ("init", cmdData) -> do
      mapData <- Txt.readFile "worlds/simple.csv"
      std <- Rnd.getStdGen
      
      case initialiseConnection conn cmdData mapData std of
        Right world -> do
          worldV <- atomically $ newTVar world
          sendConfig conn $ world ^. wdConfig
          runConnection worldV
        Left e ->
          sendError conn e
        
    _ ->
      pass

  where
    runConnection worldV = 
      forever $ do
        t <- conn ^. conReceiveText

        case parseCommand t of
          Nothing -> putText $ "error parsing: " <> t
          Just (cmd, cmdData) -> runCmd conn worldV cmd cmdData

    parseCommand :: Text -> Maybe (Text, [Text])
    parseCommand t =
      case Txt.splitOn "|" t of
        (c:d) -> Just (c, d)
        _ -> Nothing
      

initialiseConnection :: Host.Connection -> [Text] -> Text -> Rnd.StdGen -> Either Text World
initialiseConnection conn cmdData mapData std = 
  case parseScreenSize cmdData of
    Nothing ->
      Left "missing / invalid screen size"

    Just (width, height) ->
      Right $ bootWorld conn (width, height) mapData std


bootWorld :: Host.Connection -> (Int, Int) -> Text -> Rnd.StdGen -> World
bootWorld conn screenSize mapData std = 
  let
    config = mkConfig
    bug = mkEnemyActor "bug1" E.Bug (6, -2)
    snake = mkEnemyActor "snake1" E.Snake (8, -4)
  in
   
  World { _wdPlayer = mkPlayer
        , _wdConfig = config
        , _wdMap = loadWorld E.loadTexts mapData
        , _wdActors = Map.fromList [ (bug ^. acId, bug)
                                   , (snake ^. acId, snake)
                                   ]
        }
  where
    mkConfig =
{-! SECTION< 06_keys !-}
      Config { _cfgKeys = Map.fromList [ ("up"      , "Move:up")
                                       , ("k"       , "Move:up")
                                       , ("down"    , "Move:down")
                                       , ("j"       , "Move:down")
                                       , ("left"    , "Move:left")
                                       , ("h"       , "Move:left")
                                       , ("right"   , "Move:right")
                                       , ("l"       , "Move:right")
                                       , ("u"       , "Move:up-right")
                                       , ("pageup"  , "Move:up-right")
                                       , ("y"       , "Move:up-left")
                                       , ("home"    , "Move:up-left")
                                       , ("n"       , "Move:down-right")
                                       , ("end"     , "Move:down-left")
                                       , ("b"       , "Move:down-left")
                                       , ("pagedown", "Move:down-right")
                                       ]
             }
{-! SECTION> 06_keys !-}

    mkPlayer =
      Player { _plConn = conn
             , _plScreenSize = screenSize
             , _plWorldTopLeft = WorldPos (0, 0)
             , _plActor = mkPlayersActor
             }

    mkPlayersActor =
      Actor { _acId = Aid "player"
            , _acClass = ClassPlayer
            , _acEntity = E.getEntity E.Player
            , _acWorldPos = WorldPos (1, -1)
            , _acStdGen = std
            }

    mkEnemyActor aid e (x, y) =
      Actor { _acId = Aid aid
            , _acClass = ClassEnemy
            , _acEntity = E.getEntity e
            , _acWorldPos = WorldPos (x, y)
            , _acStdGen = std
            }
    

runCmd :: Host.Connection -> TVar World -> Text -> [Text] -> IO ()
runCmd conn worldV cmd cmdData = 
  case cmd of
    "redraw" -> 
      case parseScreenSize cmdData of
        Nothing -> sendError conn "missing / invalid screen size"
        Just (sx, sy) -> do
          updatePlayer (plScreenSize .~ (sx, sy))
          w <- atomically $ readTVar worldV
          drawAndSend w
          sendLog conn "draw"
      
{-! SECTION< 06_key_handle !-}
    "key" -> do
      -- Handle the key press
      atomically $ modifyTVar' worldV (\w -> runActions w $ handleKey cmdData)
      -- Get the updated world
      w2 <- atomically $ readTVar worldV
      -- Draw
      drawAndSend w2
{-! SECTION> 06_key_handle !-}

    _ ->
      sendError conn $ "Unknown command: " <> cmd

  where
    updatePlayer f = atomically $ modifyTVar' worldV (\w -> w & wdPlayer %~ f)

  
sendLog :: Host.Connection -> Text -> IO ()
sendLog conn err =
  sendData conn $ Ae.encodeText $ UiMessage "log" err


sendError :: Host.Connection -> Text -> IO ()
sendError conn err =
  sendData conn $ Ae.encodeText $ UiMessage "error" err


sendConfig :: Host.Connection -> Config -> IO ()
sendConfig conn config =
  sendData conn . Ae.encodeText $ UiConfig "config" (buildConfig config)


buildConfig :: Config -> UiConfigData
buildConfig cfg =
  UiConfigData { udKeys = buildKeys (cfg ^. cfgKeys)
               , udBlankId = E.getTile E.Blank ^. tlId
               }

  where
    buildKeys ks = buildKey <$> Map.toList ks
    buildKey (s, a) = UiKey s a


sendData :: Host.Connection -> Text -> IO ()
sendData conn t = do
  let lz = Bz.compress . BSL.fromStrict . TxtE.encodeUtf8 $ t
  conn ^. conSendData $ lz


parseScreenSize :: [Text] -> Maybe (Int, Int)
parseScreenSize cmd = do
  (tx, ty) <- case cmd of
                (tx : ty : _) -> Just (tx, ty)
                _ -> Nothing

  x <- (readMaybe . Txt.unpack $ tx) :: Maybe Int
  y <- (readMaybe . Txt.unpack $ ty) :: Maybe Int
  pure (x, y)


drawAndSend :: World -> IO ()
drawAndSend world = do
  let playerTiles = drawTilesForPlayer world (world ^. wdMap) 
  
  let cmd = Ae.encodeText UiDrawCommand { drCmd = "draw"
                                        , drScreenWidth = world ^. wdPlayer ^. plScreenSize ^. _1
                                        , drMapData = mkDrawMapData <$> Map.toList playerTiles
                                        }
  sendData (world ^. wdPlayer ^. plConn) cmd

  where
    mkDrawMapData :: (PlayerPos, Tile) -> (Int, Int, Int)
    mkDrawMapData (PlayerPos (x, y), tile) = (x, y, tile ^. tlId)

  
loadWorld :: Map Text Entity -> Text -> Map WorldPos Entity
loadWorld chars csv = 
  translatePlayerMap (WorldPos (0, 0)) $ parseWorld chars csv


parseWorld :: Map Text Entity -> Text -> Map PlayerPos Entity
parseWorld chars csv = 
  let ls = Txt.lines csv in
  let lss = Txt.strip <<$>> (Txt.splitOn "," <$> ls) in
  let entityMap = Lst.imap (\r cs -> Lst.imap (loadCol r) cs) lss in
  Map.fromList . catMaybes $ concat entityMap

  where
    loadCol y x c = case Map.lookup c chars of
                      Nothing -> Nothing
                      Just a -> Just (PlayerPos (x, y), a)


translatePlayerMap :: WorldPos -> Map PlayerPos Entity -> Map WorldPos Entity
translatePlayerMap worldTopLeft entityMap =
  let entitysInWorld = Ar.first (playerCoordToWorld worldTopLeft) <$> Map.toList entityMap  in
  Map.fromList entitysInWorld


playerCoordToWorld :: WorldPos -> PlayerPos -> WorldPos
playerCoordToWorld (WorldPos (worldTopX, worldTopY)) (PlayerPos (playerX, playerY)) =
   WorldPos (worldTopX + playerX, worldTopY - playerY)


worldCoordToPlayer :: WorldPos -> WorldPos -> PlayerPos
worldCoordToPlayer (WorldPos (worldTopX, worldTopY)) (WorldPos (worldX, worldY)) =
   PlayerPos (worldX - worldTopX, -(worldY - worldTopY))

  
drawTilesForPlayer :: World -> Map WorldPos Entity -> Map PlayerPos Tile
drawTilesForPlayer world entityMap =
  let
    player = world ^. wdPlayer
    
    -- Top left of player's grid
    (WorldPos (topX, topY)) = player ^. plWorldTopLeft 

    -- Players screen/grid dimensions
    (screenX, screenY) = player ^. plScreenSize 

    -- Bottom right corner
    (bottomX, bottomY) = (topX + screenX, topY - screenY) 

    -- Filter out blank
    noEmptyMap = Map.filter (\e -> e ^. enTile ^. tlName /= "blank") entityMap 

    -- Add the actors to the map.
    -- Notice that this will replace whatever entity was there (for this draw)
    -- This fold works by
    --    - Starting with the map of entities that are not blank
    --    - Inserting each actor into the updated map (the accumulator)
    -- getAllActors is called to get the player's actor and all other actors
    noEmptyMapWithActors = foldr
                           (\actor accum -> Map.insert (actor ^. acWorldPos) (actor ^. acEntity) accum)
                           noEmptyMap
                           (getAllActors world)

    -- Only get the entitys that are at positions on the player's screen
    visibleEntitys = Map.filterWithKey (inView topX topY bottomX bottomY) noEmptyMapWithActors

    -- Get the tile for each entity
    tileMap = (^. enTile) <$> visibleEntitys 
  in
  -- Get it with player positions
  Map.mapKeys (worldCoordToPlayer $ player ^. plWorldTopLeft) tileMap

  where
    inView topX topY bottomX bottomY (WorldPos (x, y)) _ =
      x >= topX && x < bottomX && y > bottomY && y <= topY


getAllActors :: World -> [Actor]
getAllActors world =
  world ^. wdPlayer ^. plActor : Map.elems (world ^. wdActors)


{-! SECTION< 06_handleKey !-}
handleKey :: [Text] -> [RogueAction]
handleKey (cmd:_) = 
  case cmd of
    "Move:up"         -> [ActMovePlayer ( 0,  1)]
    "Move:down"       -> [ActMovePlayer ( 0, -1)]
    "Move:left"       -> [ActMovePlayer (-1,  0)]
    "Move:right"      -> [ActMovePlayer ( 1,  0)]
    "Move:up-right"   -> [ActMovePlayer ( 1,  1)]
    "Move:up-left"    -> [ActMovePlayer (-1,  1)]
    "Move:down-right" -> [ActMovePlayer ( 1, -1)]
    "Move:down-left"  -> [ActMovePlayer (-1, -1)]
    _                 -> []
handleKey _ = []
{-! SECTION> 06_handleKey !-}


{-! SECTION< 06_runActions !-}
runActions :: World -> [RogueAction] -> World
runActions world actions =
  foldl' runAction world actions


runAction :: World -> RogueAction -> World
runAction world action =
  case action of
    ActMovePlayer (dx, dy) ->
{-! SECTION< 06_movePlayer !-}
      world & (wdPlayer . plActor . acWorldPos) %~ (\(WorldPos (x, y)) -> WorldPos (x + dx, y + dy))
{-! SECTION> 06_movePlayer !-}
{-! SECTION> 06_runActions !-}
