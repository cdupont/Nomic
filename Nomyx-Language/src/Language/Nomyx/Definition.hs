{-# LANGUAGE DeriveDataTypeable, GADTs, ScopedTypeVariables, TupleSections, TemplateHaskell, QuasiQuotes #-}

-- | All the building blocks to build rules.
module Language.Nomyx.Definition where

import Language.Nomyx.Expression
import Data.Typeable
import Control.Monad.State
import Data.List
import Data.Maybe
import Data.Time hiding (getCurrentTime)
import qualified Data.Map as M
import Data.Map hiding (map, filter, insert, mapMaybe, null)
import System.Locale (defaultTimeLocale, rfc822DateFormat)
import Data.Time.Recurrence hiding (filter)
import Safe
import Data.Lens
import Control.Applicative
import qualified Language.Haskell.TH as TH
import Language.Haskell.TH.Quote

-- * Variables
-- | variable creation
newVar :: (Typeable a, Show a, Eq a) => VarName -> a -> Exp (Maybe (V a))
newVar = NewVar

newVar_ :: (Typeable a, Show a, Eq a) => VarName -> a -> Exp (V a)
newVar_ s a = do
    mv <- NewVar s a
    case mv of
        Just var -> return var
        Nothing -> error "newVar_: Variable existing"

-- | variable reading
readVar :: (Typeable a, Show a, Eq a) => (V a) -> Exp (Maybe a)
readVar = ReadVar

readVar_ :: forall a. (Typeable a, Show a, Eq a) => (V a) -> Exp a
readVar_ v@(V a) = do
    ma <- ReadVar v
    case ma of
        Just (val:: a) -> return val
        Nothing -> error $ "readVar_: Variable \"" ++ a ++ "\" with type \"" ++ (show $ typeOf v) ++ "\" not existing"

-- | variable writing
writeVar :: (Typeable a, Show a, Eq a) => (V a) -> a -> Exp Bool
writeVar = WriteVar

writeVar_ :: (Typeable a, Show a, Eq a) => (V a) -> a -> Exp ()
writeVar_ var val = do
    ma <- WriteVar var val
    case ma of
       True -> return ()
       False -> error "writeVar_: Variable not existing"

-- | modify a variable using the provided function
modifyVar :: (Typeable a, Show a, Eq a) => (V a) -> (a -> a) -> Exp ()
modifyVar v f = writeVar_ v . f =<< readVar_ v

-- | delete variable
delVar :: (V a) -> Exp Bool
delVar = DelVar

delVar_ :: (V a) -> Exp ()
delVar_ v = DelVar v >> return ()

-- * Variable arrays
-- | ArrayVar is an indexed array with a signal attached to warn when the array is filled.
--each indexed elements starts empty (value=Nothing), and when the array is full, the signal is triggered.
--This is useful to wait for a serie of events to happen, and trigger a computation on the collected results.
data ArrayVar i a = ArrayVar (Event (Message [(i, Maybe a)])) (V (Map i (Maybe a)))

-- | initialize an empty ArrayVar
newArrayVar :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => VarName -> [i] -> Exp (ArrayVar i a)
newArrayVar name l = do
    let list = map (\i -> (i, Nothing)) l
    v <- newVar_ name (fromList list)
    return $ ArrayVar (Message name) v

-- | initialize an empty ArrayVar, registering a callback that will be triggered when the array is filled
newArrayVar' :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => VarName -> [i] -> ([(i,Maybe a)] -> Exp ()) -> Exp (ArrayVar i a)
newArrayVar' name l f = do
    av@(ArrayVar m _) <- newArrayVar name l
    onMessage m $ f . messageData
    return av

-- | initialize an empty ArrayVar, registering a callback.
--the callback will be triggered when the array is filled, and then the ArrayVar will be deleted
newArrayVarOnce :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => VarName -> [i] -> ([(i, Maybe a)] -> Exp ()) -> Exp (ArrayVar i a)
newArrayVarOnce name l f = do
   av@(ArrayVar m _) <- newArrayVar name l
   onMessage m $ \a -> do
      f $ messageData a
      full <- (isFullArrayVar av)
      when full $ delArrayVar av
   return av where


isFullArrayVar :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> Exp (Bool)
isFullArrayVar av = do
   d <- getArrayVarData av
   let full = and $ map isJust $ map snd d
   return full
   
-- | store one value and the given index. If this is the last filled element, the registered callbacks are triggered.
putArrayVar :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> i -> a -> Exp ()
putArrayVar (ArrayVar m v) i a = do
    ar <- readVar_ v
    let ar2 = M.insert i (Just a) ar
    writeVar_ v ar2
    sendMessage m (toList ar2)

-- | get the messsage triggered when the array is filled
getArrayVarMessage :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> Exp (Event (Message [(i, Maybe a)]))
getArrayVarMessage (ArrayVar m _) = return m

-- | get the association array
getArrayVarData :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> Exp ([(i, Maybe a)])
getArrayVarData (ArrayVar _ v) = toList <$> (readVar_ v)

-- | get the association array with only the filled values
getArrayVarData' :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> Exp ([(i, a)])
getArrayVarData' v = catMaybes . map sndMaybe <$> (getArrayVarData v)

delArrayVar :: (Ord i, Typeable a, Show a, Eq a, Typeable i, Show i) => (ArrayVar i a) -> Exp ()
delArrayVar (ArrayVar m v) = delAllEvents m >> delVar_ v

-- * Events

-- | register a callback on an event
onEvent :: (Typeable e, Show e, Eq e) => Event e -> ((EventNumber, EventData e) -> Exp ()) -> Exp EventNumber
onEvent = OnEvent

-- | register a callback on an event, disregard the event number
onEvent_ :: forall e. (Typeable e, Show e, Eq e) => Event e -> (EventData e -> Exp ()) -> Exp ()
onEvent_ e h = do
    OnEvent e (\(_, d) -> h d)
    return ()

-- | set an handler for an event that will be triggered only once
onEventOnce :: (Typeable e, Show e, Eq e) => Event e -> (EventData e -> Exp ()) -> Exp EventNumber
onEventOnce e h = do
    let handler (en, ed) = delEvent_ en >> h ed
    n <- OnEvent e handler
    return n

-- | set an handler for an event that will be triggered only once
onEventOnce_ :: (Typeable e, Show e, Eq e) => Event e -> (EventData e -> Exp ()) -> Exp ()
onEventOnce_ e h = do
    let handler (en, ed) = delEvent_ en >> h ed
    OnEvent e handler
    return ()

delEvent :: EventNumber -> Exp Bool
delEvent = DelEvent

delEvent_ :: EventNumber -> Exp ()
delEvent_ e = delEvent e >> return ()

delAllEvents :: (Typeable e, Show e, Eq e) => Event e -> Exp ()
delAllEvents = DelAllEvents

-- | broadcast a message that can be catched by another rule
sendMessage :: (Typeable a, Show a, Eq a) => Event (Message a) -> a -> Exp ()
sendMessage = SendMessage

sendMessage_ :: Event (Message ()) -> Exp ()
sendMessage_ m = SendMessage m ()

-- | subscribe on a message 
onMessage :: (Typeable m, Show m) => Event (Message m) -> ((EventData (Message m)) -> Exp ()) -> Exp ()
onMessage m f = onEvent_ m f

onMessageOnce :: (Typeable m, Show m) => Event (Message m) -> ((EventData (Message m)) -> Exp ()) -> Exp ()
onMessageOnce m f = onEventOnce_ m f

-- | on the provided schedule, the supplied function will be called
schedule :: (Schedule Freq) -> (UTCTime -> Exp ()) -> Exp ()
schedule sched f = do
    now <- getCurrentTime
    let next = head $ starting now $ sched
    if (next == now) then executeAndScheduleNext (f . timeData) sched (TimeData now)
                     else onEventOnce_ (Time next) $ executeAndScheduleNext (f . timeData) sched where

executeAndScheduleNext :: (EventData Time -> Exp ()) -> (Schedule Freq) -> (EventData Time) -> Exp ()
executeAndScheduleNext f sched now = do
   f now
   let rest = drop 1 $ starting (timeData now) $ sched
   when (rest /= []) $ onEventOnce_ (Time $ head rest) $ executeAndScheduleNext f sched


schedule_ :: (Schedule Freq) -> Exp () -> Exp ()
schedule_ ts f = schedule ts (\_-> f)

--at each time provided, the supplied function will be called
schedule' :: [UTCTime] -> (UTCTime -> Exp ()) -> Exp ()
schedule' sched f = do
    let sched' = sort sched
    now <- getCurrentTime
    let nextMay = headMay $ filter (>=now) $ sched'
    case nextMay of
        Just next -> do
           if (next == now) then executeAndScheduleNext' (f . timeData) sched' (TimeData now)
                     else onEventOnce_ (Time next) $ executeAndScheduleNext' (f . timeData) sched'
        Nothing -> return ()
            

executeAndScheduleNext' :: (EventData Time -> Exp ()) -> [UTCTime] -> (EventData Time) -> Exp ()
executeAndScheduleNext' f sched now = do
   f now
   let rest = drop 1 $ sched
   when (rest /= []) $ onEventOnce_ (Time $ head rest) $ executeAndScheduleNext' f sched
   

schedule'_ :: [UTCTime] -> Exp () -> Exp ()
schedule'_ ts f = schedule' ts (\_-> f)

-- * Rule management

-- | activate a rule: change its state to Active and execute it
activateRule :: RuleNumber -> Exp Bool
activateRule = ActivateRule

activateRule_ :: RuleNumber -> Exp ()
activateRule_ r = activateRule r >> return ()

-- | reject a rule: change its state to Suppressed and suppresses all its environment (events, variables, inputs)
-- the rule can be activated again later
rejectRule :: RuleNumber -> Exp Bool
rejectRule = RejectRule

rejectRule_ :: RuleNumber -> Exp ()
rejectRule_ r = rejectRule r >> return ()

getRules :: Exp [Rule]
getRules = GetRules

getActiveRules :: Exp [Rule]
getActiveRules = return . (filter ((== Active) . _rStatus) ) =<< getRules

getRule :: RuleNumber -> Exp (Maybe Rule)
getRule rn = do
   rs <- GetRules
   return $ find ((== rn) . getL rNumber) rs

getRulesByNumbers :: [RuleNumber] -> Exp [Rule]
getRulesByNumbers rns = mapMaybeM getRule rns

getRuleFuncs :: Exp [RuleFunc]
getRuleFuncs = return . (map _rRuleFunc) =<< getRules

-- | add a rule to the game, it will have to be activated 
addRule :: Rule -> Exp Bool
addRule r = AddRule r

addRule_ :: Rule -> Exp ()
addRule_ r = AddRule r >> return ()

addRuleParams_ :: RuleName -> RuleFunc -> RuleCode -> RuleNumber -> String -> Exp ()
addRuleParams_ name func code number desc = addRule_ $ defaultRule {_rName = name, _rRuleFunc = func, _rRuleCode = code, _rNumber = number, _rDescription = desc}

--suppresses completly a rule and its environment from the system
suppressRule :: RuleNumber -> Exp Bool
suppressRule rn = DelRule rn

suppressRule_ :: RuleNumber -> Exp ()
suppressRule_ rn = DelRule rn >> return ()

suppressAllRules :: Exp Bool
suppressAllRules = do
    rs <- getRules
    res <- mapM (suppressRule . _rNumber) rs
    return $ and res

modifyRule :: RuleNumber -> Rule -> Exp Bool
modifyRule rn r = ModifyRule rn r


-- * Inputs

inputChoice :: (Eq c, Show c) => PlayerNumber -> String -> [c] -> c -> Event (InputChoice c)
inputChoice = InputChoice

inputChoiceHead :: (Eq c, Show c) => PlayerNumber -> String -> [c] -> Event (InputChoice c)
inputChoiceHead pn title choices = inputChoice pn title choices (head choices)

inputChoiceEnum :: forall c. (Enum c, Bounded c, Typeable c, Eq c,  Show c) => PlayerNumber -> String -> c -> Event (InputChoice c)
inputChoiceEnum pn title defaultChoice = inputChoice pn title (enumFrom (minBound::c)) defaultChoice

inputString :: PlayerNumber -> String -> Event InputString
inputString = InputString

-- | triggers a choice input to the user. The result will be sent to the callback
onInputChoice :: (Typeable a, Eq a,  Show a) => String -> [a] -> (EventNumber -> a -> Exp ()) -> PlayerNumber -> Exp EventNumber
onInputChoice title choices handler pn = onEvent (inputChoiceHead pn title choices) (\(en, a) -> handler en (inputChoiceData a))

-- | the same, disregard the event number
onInputChoice_ :: (Typeable a, Eq a, Show a) => String -> [a] -> (a -> Exp ()) -> PlayerNumber -> Exp ()
onInputChoice_ title choices handler pn = onEvent_ (inputChoiceHead pn title choices) (handler . inputChoiceData)

-- | the same, suppress the event after first trigger
onInputChoiceOnce :: (Typeable a, Eq a, Show a) => String -> [a] -> (a -> Exp ()) -> PlayerNumber -> Exp EventNumber
onInputChoiceOnce title choices handler pn = onEventOnce (inputChoiceHead pn title choices) (handler . inputChoiceData)

-- | the same, disregard the event number
onInputChoiceOnce_ :: (Typeable a, Eq a, Show a) => String -> [a] -> (a -> Exp ()) -> PlayerNumber -> Exp ()
onInputChoiceOnce_ title choices handler pn = onEventOnce_ (inputChoiceHead pn title choices) (handler . inputChoiceData)

-- | triggers a choice input to the user, using an enumerate as input
onInputChoiceEnum :: forall a. (Enum a, Bounded a, Typeable a, Eq a,  Show a) => String -> a -> (EventNumber -> a -> Exp ()) -> PlayerNumber -> Exp EventNumber
onInputChoiceEnum title defaultChoice handler pn = onEvent (inputChoiceEnum pn title defaultChoice) (\(en, a) -> handler en (inputChoiceData a))

-- | the same, disregard the event number
onInputChoiceEnum_ :: forall a. (Enum a, Bounded a, Typeable a, Eq a,  Show a) => String -> a -> (a -> Exp ()) -> PlayerNumber -> Exp ()
onInputChoiceEnum_ title defaultChoice handler pn = onEvent_ (inputChoiceEnum pn title defaultChoice) (handler . inputChoiceData)

-- | the same, suppress the event after first trigger
onInputChoiceEnumOnce_ :: forall a. (Enum a, Bounded a, Typeable a, Eq a,  Show a) => String -> a -> (a -> Exp ()) -> PlayerNumber -> Exp ()
onInputChoiceEnumOnce_ title defaultChoice handler pn = onEventOnce_ (inputChoiceEnum pn title defaultChoice) (handler . inputChoiceData)


-- | triggers a string input to the user. The result will be sent to the callback
onInputString :: String -> (EventNumber -> String -> Exp ()) -> PlayerNumber -> Exp EventNumber
onInputString title handler pn = onEvent (inputString pn title) (\(en, a) -> handler en (inputStringData a))

-- | asks the player pn to answer a question, and feed the callback with this data.
onInputString_ :: String -> (String -> Exp ()) -> PlayerNumber -> Exp ()
onInputString_ title handler pn = onEvent_ (inputString pn title) (handler . inputStringData)

-- | asks the player pn to answer a question, and feed the callback with this data.
onInputStringOnce_ :: String -> (String -> Exp ()) -> PlayerNumber -> Exp ()
onInputStringOnce_ title handler pn = onEventOnce_ (inputString pn title) (handler . inputStringData)


-- * Victory, players, output, time and self-number

-- | set victory to a list of players
setVictory :: [PlayerNumber] -> Exp ()
setVictory = SetVictory

-- | give victory to one player
giveVictory :: PlayerNumber -> Exp ()
giveVictory pn = SetVictory [pn]

getPlayers :: Exp [PlayerInfo]
getPlayers = GetPlayers

-- | Get the total number of players
getPlayersNumber :: Exp Int
getPlayersNumber = length <$> getPlayers

getAllPlayerNumbers :: Exp [PlayerNumber]
getAllPlayerNumbers = map _playerNumber <$> getPlayers


-- | outputs a message to one player
output :: String -> PlayerNumber -> Exp ()
output s pn = Output pn s

outputAll :: String -> Exp ()
outputAll s = getPlayers >>= mapM_ ((output s) . _playerNumber)

getCurrentTime :: Exp UTCTime
getCurrentTime = CurrentTime

-- | allows a rule to retrieve its self number (for auto-deleting for example)
getSelfRuleNumber :: Exp RuleNumber
getSelfRuleNumber = SelfRuleNumber

getSelfRule :: Exp Rule
getSelfRule  = do
   srn <- getSelfRuleNumber
   rs:[] <- getRulesByNumbers [srn]
   return rs

getSelfProposedByPlayer :: Exp PlayerNumber
getSelfProposedByPlayer = getSelfRule >>= return . _rProposedBy


-- * Miscellaneous

mapMaybeM :: (Monad m) => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f = liftM catMaybes . mapM f

parse822Time :: String -> UTCTime
parse822Time = zonedTimeToUTC
              . fromJust
              . parseTime defaultTimeLocale rfc822DateFormat

sndMaybe :: (a, Maybe b) -> Maybe (a,b)
sndMaybe (a, Just b) = Just (a,b)
sndMaybe (_, Nothing) = Nothing


--combine two rule responses
andrr :: RuleResponse -> RuleResponse -> Exp RuleResponse
andrr a@(BoolResp _)           b@(MsgResp _)                = andrr b a
andrr (BoolResp a)               (BoolResp b)               = return $ BoolResp $ a && b
andrr (MsgResp (Message s1)) (MsgResp (Message s2)) = do
    let m = Message (s1 ++ " and " ++ s2)
    newArrayVarOnce (s1 ++ ", " ++ s2) [1::Integer, 2] (f m)
    return (MsgResp m) where
        f m ((_, Just a):(_, Just b):[]) = sendMessage m $ a && b
        f _ _ = return ()
andrr (MsgResp m1@(Message s1)) (BoolResp b2) =  do
    let m = Message (s1 ++ " and " ++ (show b2))
    onMessageOnce m1 (f m)
    return (MsgResp m) where
        f m (MessageData b1) = sendMessage m $ b1 && b2

andrrs :: [RuleResponse] -> Exp RuleResponse
andrrs l = foldM andrr (BoolResp True) l

--combine two rules
(&&.) :: RuleFunc -> RuleFunc -> RuleFunc
(VoidRule r1) &&. (VoidRule r2) =  VoidRule $ r1 >> r2
rf1@(VoidRule _) &&. rf2@(RuleRule _) =  rf2 &&. rf1
(RuleRule r1) &&. (VoidRule r2) =  RuleRule $ \a -> do
    res <- r1 a
    r2
    return res
(RuleRule r1) &&. (RuleRule r2) =  RuleRule $ \a -> do
    res1 <- r1 a
    res2 <- r2 a
    res <- andrr res1 res2
    return res
_ &&. _ = error "rules impossible to combine"

-- | a default rule
defaultRule = Rule  {
    _rNumber       = 1,
    _rName         = "",
    _rDescription  = "",
    _rProposedBy   = 0,
    _rRuleCode     = "",
    _rRuleFunc     = VoidRule $ return (),
    _rStatus       = Pending,
    _rAssessedBy   = Nothing}
