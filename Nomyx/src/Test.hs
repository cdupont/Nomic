-----------------------------------------------------------------------------
--
-- Module      :  Test
-- Copyright   :
-- License     :  BSD3
--
-- Maintainer  :  corentin.dupont@gmail.com
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Test module
module Test where

import Prelude
import Types
import Control.Monad.State
import Multi
import Language.Haskell.Interpreter.Server (ServerHandle)
import Language.Nomyx hiding (getCurrentTime)
import Language.Nomyx.Engine
import Control.Applicative
import Control.Exception as E
import Language.Haskell.TH
import Language.Haskell.TH.Syntax as THS hiding (lift)
import System.IO.Unsafe
import Quotes
import Data.Lens
import Data.List
import Safe
import Data.Acid.Memory
import Happstack.Auth.Core.Auth (initialAuthState)
import Happstack.Auth.Core.Profile (initialProfileState)
import qualified Language.Nomyx.Engine as G
import Control.Arrow ((>>>))
import Data.Time hiding (getCurrentTime)

playTests :: ServerHandle -> IO [(String, Bool)]
playTests sh = mapM (\(title, t, cond) -> (title,) <$> test sh t cond) tests

-- | test list.
-- each test can be loaded individually in Nomyx with the command line:
-- Nomyx -l <"test name">
tests :: [(String, StateT Session IO (), Multi -> Bool)]
tests = [("hello World",           gameHelloWorld,         condHelloWorld),
         ("hello World 2 players", gameHelloWorld2Players, condHelloWorld2Players),
         ("Partial Function 1",    gamePartialFunction1,   condPartialFunction1),
         ("Partial Function 2",    gamePartialFunction2,   condPartialFunction2),
         ("Partial Function 3",    gamePartialFunction3,   condPartialFunction3),
         ("Money transfer",        gameMoneyTransfer,      condMoneyTransfer)]

dayZero :: UTCTime
dayZero = UTCTime (ModifiedJulianDay 0) 0


test :: ServerHandle -> StateT Session IO () -> (Multi -> Bool) -> IO Bool
test sh tes cond = do
   tp <- testProfiles
   let s = Session sh (defaultMulti (Settings defaultNetwork False "" "" "" "")) tp
   m' <- loadTest tes s
   (evaluate $ cond m') `E.catch` (\(e::SomeException) -> (putStrLn $ "Exception in test: " ++ show e) >> return False)

loadTest ::  StateT Session IO () -> Session -> IO Multi
loadTest tes s = do
   ms <- updateSession' s tes
   case ms of
      Just s' -> return $ _multi s'
      Nothing -> error "updateSession failed"


testException :: Multi -> SomeException -> IO Multi
testException m e = do
   putStrLn $ "Test Exception: " ++ show e
   return m

loadTestName :: Settings -> String -> ServerHandle -> IO Multi
loadTestName set testName sh = do
   let mt = find (\(name, _, _) -> name == testName) tests
   tp <- testProfiles
   let s = Session sh (defaultMulti set) tp
   case mt of
      Just (n, t, _) -> putStrLn ("Loading test game: " ++ n)  >> loadTest t s
      Nothing -> do
         putStrLn "Test name not found"
         return $ _multi s

testProfiles :: IO Profiles
testProfiles = do
   ias  <- openMemoryState initialAuthState
   ips  <- openMemoryState initialProfileState
   ipds <- openMemoryState initialProfileDataState
   return $ Profiles ias ips ipds

printRule :: Q THS.Exp -> String
printRule r = unsafePerformIO $ do
   expr <- runQ r
   return $ pprint expr


onePlayerOneGame :: StateT Session IO ()
onePlayerOneGame = do
   newPlayer 1 (PlayerSettings {_pPlayerName = "Player 1", _mail = "", _mailNewInput = False, _mailNewRule = False, _mailNewOutput = False, _mailConfirmed = False})
   newGame "test" (GameDesc "" "") 1
   joinGame "test" 1
   viewGamePlayer "test" 1

twoPlayersOneGame :: StateT Session IO ()
twoPlayersOneGame = do
   onePlayerOneGame
   newPlayer 2 (PlayerSettings {_pPlayerName = "Player 2", _mail = "", _mailNewInput = False, _mailNewRule = False, _mailNewOutput = False, _mailConfirmed = False})
   joinGame "test" 2
   viewGamePlayer "test" 2

submitR :: String -> StateT Session IO ()
submitR r = do
   onePlayerOneGame
   sh <- access sh
   submitRule (SubmitRule "" "" r) 1 "test" sh
   inputAllRadios 0 1

-- select first choice for all radio buttons
inputAllRadios :: Int -> PlayerNumber -> StateT Session IO ()
inputAllRadios choice pn = do
   s <- get
   let evs = evalState getChoiceEvents (_game $ head $ _games $ _multi s)
   mapM_ (\en -> inputResult pn en (URadioData choice) "test") evs

inputAllTexts :: String -> PlayerNumber -> StateT Session IO ()
inputAllTexts a pn = do
   s <- get
   let evs = evalState getTextEvents (_game $ head $ _games $ _multi s)
   mapM_ (\en -> inputResult pn en (UTextData a) "test") evs

gameHelloWorld :: StateT Session IO ()
gameHelloWorld = submitR [cr|helloWorld|]

condHelloWorld :: Multi -> Bool
condHelloWorld m = isOutput "hello, world!" m

gameHelloWorld2Players :: StateT Session IO ()
gameHelloWorld2Players = do
   twoPlayersOneGame
   sh <- access sh
   submitRule (SubmitRule "" "" [cr|helloWorld|]) 1 "test" sh
   inputAllRadios 0 1
   inputAllRadios 0 2

condHelloWorld2Players :: Multi -> Bool
condHelloWorld2Players m = isOutput "hello, world!" m

partialFunction1 :: String
partialFunction1 = [cr|ruleFunc $ readMsgVar_ (msgVar "toto1" :: MsgVar String)|]

gamePartialFunction1 :: StateT Session IO ()
gamePartialFunction1 = submitR partialFunction1

-- rule has not been accepted due to exception
condPartialFunction1 :: Multi -> Bool
condPartialFunction1 m = (_rStatus $ head $ _rules $ G._game $ head $ _games m) == Active &&
                         (take 5 $ _lMsg $ head $ _logs $ G._game $ head $ _games m) == "Error"

partialFunction2 :: String
partialFunction2 = [cr|ruleFunc $ do
   t <- liftEffect getCurrentTime
   onEventOnce (Time $ addUTCTime 5 t) $ const $ readMsgVar_ (msgVar "toto2")|]

gamePartialFunction2 :: StateT Session IO ()
gamePartialFunction2 = do
   onePlayerOneGame
   submitR partialFunction2
   gs <- (access $ multi >>> games)
   let now = _currentTime $ G._game (head gs)
   focus multi $ triggerTimeEvent (5 `addUTCTime` now)

-- rule has been accepted but exception happened later
condPartialFunction2 :: Multi -> Bool
condPartialFunction2 m = (_rStatus $ headNote "cond1 failed" $ _rules $ G._game $ headNote "cond2 failed" $ _games m) == Active &&
                         (take 5 $ _lMsg $ headNote "cond3 failed" $ _logs $ G._game $ headNote "cond4 failed" $ _games m) == "Error"

partialFunction3 :: String
partialFunction3 = [cr|ruleFunc $ onEvent_ (RuleEv Proposed) $ const $ readMsgVar_ (msgVar "toto3")|]

gamePartialFunction3 :: StateT Session IO ()
gamePartialFunction3 = do
   submitR partialFunction3
   submitR [cr|nothing|]

-- rule has been accepted and also next one
condPartialFunction3 :: Multi -> Bool
condPartialFunction3 m = (length $ _rules $ G._game $ head $ games ^$ m) == 4

--Create bank accounts, win 100 Ecu on rule accepted (so 100 Ecu is won for each player), transfer 50 Ecu
gameMoneyTransfer :: StateT Session IO ()
gameMoneyTransfer = do
   sh <- access sh
   twoPlayersOneGame
   submitRule (SubmitRule "" "" [cr|createBankAccount|]) 1 "test" sh
   submitRule (SubmitRule "" "" [cr|winXEcuOnRuleAccepted 100|]) 1 "test" sh
   submitRule (SubmitRule "" "" [cr|moneyTransfer|]) 2 "test" sh
   inputAllRadios 0 1
   inputAllRadios 0 2
   inputAllTexts "50" 1
   s <- get
   liftIO $ putStrLn $ displayGame $ G._game $ head $ _games $ _multi s

condMoneyTransfer :: Multi -> Bool
condMoneyTransfer m = (_vName $ head $ _variables $ G._game $ head $ _games m) == "Accounts"


--voidRule $ let a = a + 1 in outputAll (show a)

isOutput :: String -> Multi -> Bool
isOutput s g = any (\g -> any (\(Output _ _ _ mys SActive) -> mys == s) (_outputs $ G._game g)) (_games g)
