{-# LANGUAGE StandaloneDeriving, GADTs, DeriveDataTypeable,
    FlexibleContexts, GeneralizedNewtypeDeriving,
    MultiParamTypeClasses, TemplateHaskell, TypeFamilies,
    TypeOperators, FlexibleInstances, NoMonomorphismRestriction,
    TypeSynonymInstances, DoAndIfThenElse, RecordWildCards #-}

-- | This module implements Game management.
-- a game is a set of rules, and results of actions made by players (usually vote results)
-- the module manages the effects of rules over each others.
module Language.Nomyx.Game (GameEvent(..), update, update', LoggedGame(..), game, gameLog, emptyGame,
  execWithGame, execWithGame', outputAll, getLoggedGame, tracePN, getTimes, activeRules, pendingRules, rejectedRules)  where

import Prelude hiding (catch)
import Language.Nomyx.Rule
import Control.Monad.State
import Data.List
import Language.Nomyx hiding (outputAll)
import Data.Lens
import Control.Category ((>>>))
import Debug.Trace.Helpers (traceM)
import Data.Lens.Template
import Data.Time as T
import Control.Applicative ((<$>))
import Data.SafeCopy        ( base, deriveSafeCopy )
import Control.Exception


data TimedEvent = TimedEvent {time::UTCTime, gameEvent :: GameEvent} deriving (Show, Read, Eq, Ord)

data GameEvent = JoinGame              PlayerNumber PlayerName
               | LeaveGame             PlayerNumber
               | ProposeRuleEv         PlayerNumber SubmitRule
               | InputChoiceResult     PlayerNumber EventNumber Int
               | InputStringResult     PlayerNumber String String
               | OutputPlayer          PlayerNumber String
               | TimeEvent             UTCTime
                 deriving (Show, Read, Eq, Ord)

data LoggedGame = LoggedGame { _game :: Game,
                               _gameLog :: [TimedEvent]}
                               deriving (Show)

instance Read LoggedGame where
   readsPrec a s = [(LoggedGame dummyGame (fst $ head $ readsPrec a s), s)]

instance Eq LoggedGame where
   (LoggedGame {_game=g1}) == (LoggedGame {_game=g2}) = g1 == g2

instance Ord LoggedGame where
   compare (LoggedGame {_game=g1}) (LoggedGame {_game=g2}) = compare g1 g2

emptyGame name desc date = Game {
    _gameName      = name,
    _gameDesc      = desc,
    _rules         = [],
    _players       = [],
    _variables     = [],
    _events        = [],
    _outputs       = [],
    _victory       = [],
    _currentTime   = date}


dummyGame :: Game
dummyGame = emptyGame "" (GameDesc "" "") (UTCTime (toEnum 0) 0)

$( makeLens ''LoggedGame)
-- $(deriveSafeCopy 0 'base ''SubmitRule)
-- $(deriveSafeCopy 0 'base ''GameEvent)
-- $(deriveSafeCopy 0 'base ''TimedEvent)
-- $(deriveSafeCopy 0 'base ''GameDesc)
--
--instance SafeCopy LoggedGame where
--     putCopy (LoggedGame Game{..} gl) = contain $ do
--        safePut _gameName
--        safePut _gameDesc
--        safePut _currentTime
--        safePut gl
--     getCopy = contain $ do
--        _gameName <- safeGet
--        _gameDesc <- safeGet
--        _currentTime <- safeGet
--        gl <- safeGet
--        return $ LoggedGame (emptyGame _gameName _gameDesc _currentTime) gl


enactEvent :: GameEvent -> Maybe (RuleCode -> IO RuleFunc) -> StateT Game IO ()
enactEvent (JoinGame pn name) _               = liftT $ joinGame name pn
enactEvent (LeaveGame pn) _                   = liftT $ leaveGame pn
enactEvent (ProposeRuleEv pn sr) (Just inter) = proposeRule sr pn inter
enactEvent (InputChoiceResult pn en ci) _     = liftT $ inputChoiceResult en ci pn
enactEvent (InputStringResult pn ti res) _    = liftT $ inputStringResult (InputString pn ti) res pn
enactEvent (OutputPlayer pn s) _              = liftT $ outputPlayer s pn
enactEvent (TimeEvent t) _                    = liftT $ evTriggerTime t
enactEvent (ProposeRuleEv _ _) Nothing        = error "ProposeRuleEv: interpreter fucntion needed"

enactTimedEvent :: Maybe (RuleCode -> IO RuleFunc) -> TimedEvent -> StateT Game IO ()
enactTimedEvent inter (TimedEvent t ge) = do
   currentTime ~= t
   enactEvent ge inter


update :: GameEvent -> StateT LoggedGame IO ()
update ge = update' Nothing ge

update' :: Maybe (RuleCode -> IO RuleFunc) -> GameEvent -> StateT LoggedGame IO ()
update' inter ge = do
   t <- lift $ T.getCurrentTime
   let te = TimedEvent t ge
   gameLog %= (++) [te]
   evalTimedEvent te inter `liftCatchIO` commandExceptionHandler'

evalTimedEvent :: TimedEvent -> Maybe (RuleCode -> IO RuleFunc) -> StateT LoggedGame IO ()
evalTimedEvent te mInter = focus game $ do
   enactEvent (gameEvent te) mInter
   lg <- get
   lift $ evaluate lg
   return ()

commandExceptionHandler' :: ErrorCall -> StateT LoggedGame IO ()
commandExceptionHandler' e = do
   lift $ putStrLn $ "Exception in rule: " ++ (show e)
   outputAll $ "Error in command: " ++ (show e)


getLoggedGame :: [TimedEvent] -> Game -> (RuleCode -> IO RuleFunc) -> IO LoggedGame
getLoggedGame tes g mInter = do
   let a = mapM_ (enactTimedEvent (Just mInter)) tes
   g' <- execStateT a g
   return $ LoggedGame g' tes

-- | join the game.
joinGame :: PlayerName -> PlayerNumber -> State Game ()
joinGame name pn = do
   g <- get
   case find ((== pn) . getL playerNumber) (_players g) of
      Just _ -> return ()
      Nothing -> do
         tracePN pn $ "Joining game: " ++ (_gameName g)
         let player = PlayerInfo { _playerNumber = pn, _playerName = name}
         players %= (player : )
         triggerEvent (Player Arrive) (PlayerData player)


-- | leave the game.
leaveGame :: PlayerNumber -> State Game ()
leaveGame pn = do
   g <- get
   case find ((== pn) . getL playerNumber ) (_players g) of
      Nothing -> tracePN pn "not in game!"
      Just pl -> do
         tracePN pn $ "leaving the game: " ++ (_gameName g)
         players %= filter ((/= pn) . getL playerNumber)
         triggerEvent (Player Leave) (PlayerData pl)


-- | insert a rule in pending rules.
proposeRule :: SubmitRule -> PlayerNumber -> (RuleCode -> IO RuleFunc) -> StateT Game IO ()
proposeRule sr@(SubmitRule name desc code) pn interpret = do
   tracePN pn $ "proposed " ++ (show sr)
   rs <- access rules
   let rn = getFreeNumber $ map _rNumber rs
   rf <- lift $ interpret code
   let rule = Rule {_rNumber = rn,
                    _rName = name,
                    _rDescription = desc,
                    _rProposedBy = pn,
                    _rRuleCode = code,
                    _rRuleFunc = rf,
                    _rStatus = Pending,
                    _rAssessedBy = Nothing}
   r <- liftT $ evProposeRule rule
   if r == True then tracePN pn $ "Your rule has been added to pending rules."
   else tracePN pn $ "Error: Rule could not be proposed"


outputPlayer :: String -> PlayerNumber -> State Game ()
outputPlayer s pn = void $ outputs %= ((pn, s) : )

outputAll :: String -> StateT LoggedGame IO ()
outputAll s = do
   pls <- access (game >>> players)
   mapM_ (update . ((flip OutputPlayer) s)) (map _playerNumber pls)

inputChoiceResult :: EventNumber -> Int -> PlayerNumber -> State Game ()
inputChoiceResult eventNumber choiceIndex pn = do
   tracePN pn $ "input choice result: Event " ++ (show eventNumber) ++ ", choice " ++  (show choiceIndex)
   triggerChoice eventNumber choiceIndex

-- TODO maybe homogeneise both inputs event
inputStringResult :: Event InputString -> String -> PlayerNumber -> State Game ()
inputStringResult event input pn = do
   tracePN pn $ "input String result: input " ++ input
   triggerEvent event (InputStringData input)


getTimes :: EventHandler -> Maybe UTCTime
getTimes (EH _ _ (Time t) _) = Just t
getTimes _ = Nothing


-- | An helper function to use the state transformer GameState.
-- It additionally sets the current time.
execWithGame :: UTCTime -> State LoggedGame () -> LoggedGame -> LoggedGame
execWithGame t gs g = execState gs (setL (game >>> currentTime) t g)

execWithGame' :: UTCTime -> StateT LoggedGame IO () -> LoggedGame -> IO LoggedGame
execWithGame' t gs g = execStateT gs (setL (game >>> currentTime) t g)


--accessors

activeRules :: Game -> [Rule]
activeRules = sort . filter ((==Active) . getL rStatus) . _rules

pendingRules :: Game -> [Rule]
pendingRules = sort . filter ((==Pending) . getL rStatus) . _rules

rejectedRules :: Game -> [Rule]
rejectedRules = sort . filter ((==Reject) . getL rStatus) . _rules

instance Ord PlayerInfo where
   h <= g = (_playerNumber h) <= (_playerNumber g)

tracePN :: (Monad m ) => PlayerNumber -> String -> m ()
tracePN pn s = traceM $ "Player " ++ (show pn) ++ " " ++ s

liftT :: Show s => State s a -> StateT s IO a
liftT st = do
    s1 <- get
    let (a, s) = runState st s1
    put s
    return a


liftCatchIO :: StateT s IO a -> (ErrorCall -> StateT s IO a) -> StateT s IO a
liftCatchIO m h = StateT $ \s -> runStateT m s `catch` \e -> runStateT (h e) s