
-- | extensive testing.
-- to run all tests, run "allTests" and "testMultiX" 
module Test where

import Game
import Observable
import Control.Monad.State
import Server
import System.IO
import Control.Concurrent.STM
import Control.Concurrent
import Comm
import Interpret
import Language.Haskell.Interpreter.Server
import NamedRule
import System.IO.Unsafe (unsafePerformIO)


mysHandle = unsafePerformIO startInterpreter

testComm :: ServerHandle -> Communication
testComm sh = unsafePerformIO $ do
   cc <- liftIO $ newClientComm stdin
   liftIO $ forkIO $ clientIn cc `catch` (\_ -> putStrLn "acceptLoop: clientIn exception")
   liftIO $ forkIO $ clientOut cc `catch` (\_ -> putStrLn "acceptLoop: clientOut exception")
   return $ Communication (inChan cc) (outChan cc) sh

test :: Eq a => (StateT s Comm a) -> s -> a -> IO Bool
test state s expected = do
   inChan <- liftIO $ atomically newTChan
   outChan <- liftIO $ atomically newTChan
   let com = Communication inChan outChan mysHandle
   res <- runWithComm com  $ evalStateT state s
   --atomically $ waitForTrue $ do
   --   s <- readTChan outChan
   --   lift $ putStr s
   --   isEmptyTChan outChan
   return $ res == expected

   
-- Preliminaries
nr1 = NamedRule {rNumber=1, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rRule = r1, rStatus = Active, rejectedBy = Nothing}
nr2 = NamedRule {rNumber=2, rName ="Rule2", rText="test de règle 2", rProposedBy=2, rRule = r2, rStatus = Active, rejectedBy = Nothing}
nr3 = NamedRule {rNumber=3, rName ="Rule3", rText="test de règle 3", rProposedBy=3, rRule = r3, rStatus = Active, rejectedBy = Nothing}


rs = [nr1, nr2]

g = Game {gameName = "test", rules = rs, actionResults = [], players = []}

-- Test on Rules
defaultNRrule r = NamedRule { rNumber = 1,
                              rName = "",
                              rText = "",
                              rProposedBy = 0, 
                              rRule = r,
                              rStatus = Active,
                              rejectedBy = Nothing}
                  
r1 = "MustBeEgalTo legal"
r2 = "MustBeEgalTo (MustBeEgalTo legal)"
r3 = "legal"
r4 = "illegal"
r5 = "TestRuleOver legal"
r6 = "OfficialRule 1"           -- r6 == r1
r7 = "immutable 1"





rtest1 = test (isRuleLegal (defaultNRrule r1) nr1) g (Right False) --a program cannot contain a whole representation of itself.
rtest2 = test (isRuleLegal (defaultNRrule r2) nr1) g (Right True)  --r2 contains a representation of r1.
--rtest3 = test (isRuleLegal (defaultNRrule (r1 ++ " `Rand` " ++ r1)) nr1) g (Right False)
--rtest4 = test (isRuleLegal (defaultNRrule (r1 ++ "`Ror`" ++ r2)) nr1) g (Right True)
rtest5 = test (isRuleLegal (defaultNRrule r3) nr1) g (Right True)
rtest6 = test (isRuleLegal (defaultNRrule r4) nr1) g (Right False)
rtest7 = test (isRuleLegal (defaultNRrule r5) (defaultNRrule r1)) g (Right True)
rtest8 = test (isRuleLegal (defaultNRrule r6) (defaultNRrule r3)) g (Right True)
rtest9 = test (isRuleLegal (defaultNRrule r7) (defaultNRrule r4)) g (Right False)

ruleTestPassed = liftM and $ sequence [rtest1, rtest2, rtest5, rtest6, rtest7, rtest8, rtest9]


-- Some properties that rules must hold.

--  prop_autoContain r = do
-- 		a <- isRuleLegal p p
--                return $ not a
--   	where p = MustBeEgalTo r 

-- test on Observables

o1 = ruleOfficial
o2 = (proposedBy ==. 1) &&. ruleOfficial
o3 = (proposedBy ==. 1) ||. ruleOfficial
o4 = (proposedBy ==. 2) &&. (not_ ruleOfficial)
o5 = (proposedBy - 1) ==. 2
o6 = selfNumber ==. 1
o7 = map_ (+ (konst 1)) AllPlayers 
o8 = foldr_ (+) (konst 1) AllPlayers
o9 = and_ (konst [True, True])
o10 = or_ (konst [False, True])

otest1 = test (evalObs o1 nr1 0) g (Right True)  --(nr1 is official)
otest1' = test (evalObs o1 nr3 0) g (Right False) --(nr1 is not official and should)
otest2 = test (evalObs o2 nr1 0) g (Right False) --(nr1 is official but it's not Player 1's turn)
otest3 = test (evalObs o3 nr1 0) g (Right True)  --(nr1 is official or it's player 1 turn)
otest4 = test (evalObs o4 nr1 0) g (Right False) --(nr1 is official and should not)
otest5 = test (evalObs o5 nr1 0) g (Right False) --(nr1 is official and should not)
otest6 = test (evalObs o6 nr3 1) g (Right True)
otest7 = test (evalObs o7 nr3 1) Game {gameName = "test", rules = rs, actionResults = [], players = [PlayerInfo 3 "t", PlayerInfo 5 "u"]} (Right [4, 6])
otest8 = test (evalObs o8 nr3 1) Game {gameName = "test", rules = rs, actionResults = [], players = [PlayerInfo 3 "t", PlayerInfo 5 "u"]} (Right 9)
otest9 = test (evalObs o9 nr3 1) g (Right True)
otest10 = test (evalObs o10 nr3 1) g (Right True)

obsTestPassed = liftM and $ sequence [otest1, otest1', otest2, otest3, otest4, otest5, otest6, otest7, otest8, otest9,
   otest10 ]

--testObs :: Obs a -> Either Actions a
--testObs o = test (evalObs o nr1 0) g

-- Test with combination of the 2

-- if this rule is officialized, Player 2 cannot play anymore
cr1 = "Cond (oRuleProposedBy ==. 2) Illegal Legal" 

-- Only new rules are affected
cr2 = "Cond (oRuleOfficial) Legal Illegal" 

-- applicable only on turn 3
-- cr3 r = Cond (oTurn `oEqu` 3) r Legal

-- the total is that cr3 forbidden player 2 to play at turn 3.

crtest1 = test (isRuleLegal (defaultNRrule cr1) nr1) g (Right False) --it's Player 2 to play, cr1 forbids that
crtest2 = test (isRuleLegal (defaultNRrule cr2) nr1) g (Right True)  --nr1 is official (ie included in the current ruleset)
crtest3 = test (isRuleLegal (defaultNRrule cr2) nr3) g (Right False) --nr3 is not official

crTestPassed = liftM and $ sequence [crtest1, crtest2, crtest3]

--testRule :: String -> Either Actions Bool
--testRule r = test (isRuleLegal (defaultNRrule r) nr1) g

-- action test
--g2 = Game {gameName = "test", rules = rs, actionResults = [Action 1 2 (oVote (Konst 1)) (Konst "For")], players = []}
--
--ar1 = "Cond (Vote (Konst \"Vote\") (Konst 1) ) Legal Illegal"
--atest1 = return $ findActionResult (oVote (Konst 1))
--                           NamedRule {rNumber=2, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rule = ar1, rStatus = Active, rejectedBy = Nothing}
--                           1
--                           (actionResults g2) == Just (Action 1 2 (oVote (Konst 1)) (Just "For"))
--
--atest2 = test (evalObs (oVote (Konst 1))
--                 NamedRule {rNumber=2, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rule = ar1, rStatus = Active, rejectedBy = Nothing}
--                 1) g2 (Right True)
--
--atest3 = test (isRuleLegal' (Cond (oVote (Konst 1) ) Legal Illegal)
--                     NamedRule {rNumber=2, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rule = r1, rStatus = Pending, rejectedBy = Nothing}
--                     1) g2 (Right True)
--
--atest4 = test (isRuleLegal NamedRule {rNumber=1, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rule = ar1, rStatus = Active, rejectedBy = Nothing}
--                            NamedRule {rNumber=2, rName ="Rule1", rText="test de règle 1", rProposedBy=2, rule = r1, rStatus = Pending, rejectedBy = Nothing})
--                     g2 (Right True)
--
--actionTestPassed = liftM and $ sequence [atest1, atest2, atest3, atest4]

-- Other test


cnr1 = NamedRule {rNumber=1, rName ="Rule1", rText="test de règle 1", rProposedBy=1, rRule = cr1, rStatus = Active, rejectedBy = Nothing}
cnr2 = NamedRule {rNumber=2, rName ="Rule2", rText="test de règle 2", rProposedBy=2, rRule = cr2, rStatus = Active, rejectedBy = Nothing}

gs2 = Game {gameName="Jeu", rules = [cnr2], actionResults = [], players = []}



isRuleLegalToCurrentRuleSetTest1 = test (isLegal cnr2) gs2 (Right Nothing)

isRuleLegalToCurrentRuleSetTest2 = test (isLegal cnr1) gs2 (Right Nothing)

applyRuleToCurrentRuleSet :: IO Game
applyRuleToCurrentRuleSet = runWithComm (testComm mysHandle) $ execStateT (applyTo cnr1)  gs2 --empty the active ruleset because it's P2 turn
applyRuleToCurrentRuleSetTest = do g <- applyRuleToCurrentRuleSet
                                   return $ null ( activeRules g )

-- Visual test

playTest1 = runStateT (amend cnr1) gs2 -- the proposed rule is illegal (it is not allready official)
playTest2 = runStateT (amend cnr2) gs2 -- the proposed rule is legal (it is allready official). It is added to the ruleset. Its execution doesn't modify the ruleset.

voteTest = test (isRuleLegal (defaultNRrule ("voteRule 1")) nr1) g


-- monadic test in mono player
--
--putChan :: ClientComm -> String -> IO ()
--putChan ClientComm {inChan = ic} l = do
--   putStrLn $ "-> " ++ l
--   threadDelay 100000
--   atomically $ writeTChan ic l
--   putChar '\n'
--
--
--noVote :: ServerState
--noVote = do
--            modify (\s @ Server { multi = m@Multi { games = g:gs}} ->
--               s {multi = m{ games = g { rules = [NamedRule {rNumber=1, rName ="NoVote", rText="", rProposedBy=0, rule = "Legal", rStatus = Active, rejectedBy = Nothing},
--                                                  NamedRule {rNumber=2, rName ="Immutable Rules", rText="The rule #1 must not be suppressed", rProposedBy=0, rule = "immutable 1", rStatus = Active, rejectedBy = Nothing}]}:gs }})
--
----debugIdentify :: ServerState
--
--
---- monadic test in multi player
--testMulti1 :: IO Bool
--testMulti1 = do
--
--   --opening a handle to simulate each player
--   h1 <- openFile "/dev/stdout" ReadWriteMode
--   h2 <- openFile "/dev/stdout" ReadWriteMode
--   h3 <- openFile "/dev/stdout" ReadWriteMode
--   cc1 <- newClientComm h1
--   cc2 <- newClientComm h2
--   cc3 <- newClientComm h3
--   let put1 = putChan cc1
--   let put2 = putChan cc2
--   let put3 = putChan cc3
--
--
--   debugChan <- atomically newTChan
--   acceptChan <- atomically newTChan
--
--   forkIO $ clientOut cc1
--   forkIO $ clientOut cc2
--   forkIO $ clientOut cc3
--
--
--   forkIO $ runWithServer (defaultServer mysHandle) (mainLoop acceptChan [cc1, cc2, cc3] (debugViewState, debugChan))
--
--   -- simulate connection of the clients
--   atomically $ writeTChan acceptChan cc1
--
--   put1 "coco"
--   put1 "coco"
--   put1 "newgame g1"
--   put1 "join g1"
--
--   put1 "submitRule testRule3 testRuletext Legal"
--
--   atomically $ writeTChan acceptChan cc2
--   put2 "jaja"
--   put2 "jaja"
--   put2 "join g1"
--   put2 "submitRule testRule4 testRuletext \"eraseRule 3\""
--
--   put1 "amendconstitution"
--   put2 "submitRule testRule5 testRuletext Illegal"
--
--   put1 "showallrules"
--
--   atomically $ writeTChan acceptChan cc3
--
--   put3 "mimi"
--   put3 "mimi"
--   put3 "newgame g2"
--   put3 "join g2"
--   put3 "submitRule testRule3 testRuletext \"eraseRule 1\""
--
--   put3 "showallrules"
--
--   put1 "debug read"
--
--   s <- liftIO $ atomically $ readTChan debugChan
--   putStrLn $ show s
--   putStrLn $ show $ endServer1 mysHandle h1 h2 h3
--
--   return $ (show s) == (show $ endServer1 mysHandle h1 h2 h3)
--
--endServer1 :: ServerHandle -> Handle -> Handle -> Handle -> Server
--endServer1 sh h1 h2 h3 = Server {
--   multi = Multi {
--      games = [Game { gameName = "g1",
--                      rules = [nrVote,
--                               nrImmutable,
--                               NamedRule {rNumber=3, rName ="testRule3", rText="testRuletext", rProposedBy=1, rule = "Legal", rStatus = Pending, rejectedBy = Nothing},
--                               NamedRule {rNumber=4, rName ="testRule4", rText="testRuletext", rProposedBy=2, rule = "eraseRule 3", rStatus = Pending, rejectedBy = Nothing},
--                               NamedRule {rNumber=5, rName ="testRule5", rText="testRuletext", rProposedBy=2, rule = "Illegal", rStatus = Pending, rejectedBy = Nothing}],
--                      actionResults = [],
--                      players = [PlayerInfo {playerNumber=1, playerName ="coco"},
--                                 PlayerInfo {playerNumber=2, playerName ="jaja"}]},
--               Game { gameName = "g2",
--                      rules = [nrVote,
--                               nrImmutable,
--                               NamedRule {rNumber=3, rName ="testRule3", rText="testRuletext", rProposedBy=3, rule = "eraseRule 1", rStatus = Pending, rejectedBy = Nothing}],
--                      actionResults = [],
--                      players = [PlayerInfo {playerNumber=3, playerName ="mimi"}]}],
--      mPlayers = [PlayerMulti { mPlayerNumber = 1, mPlayerName = "coco", mPassword ="coco", inGame = Just "g1"},
--                  PlayerMulti { mPlayerNumber = 2, mPlayerName = "jaja", mPassword ="jaja", inGame = Just "g1"},
--                  PlayerMulti { mPlayerNumber = 3, mPlayerName = "mimi", mPassword ="mimi", inGame = Just "g2"}]},
--   playerClients = [PlayerClient { cPlayerNumber = 1, cHandle = h1},
--                    PlayerClient { cPlayerNumber = 2, cHandle = h2},
--                    PlayerClient { cPlayerNumber = 3, cHandle = h3}]}
--
--
---- monadic test on actions
--testMulti2 :: IO Bool
--testMulti2 = do
--
--   --opening a handle to simulate each player
--   h1 <- openFile "/dev/stdout" ReadWriteMode
--   h2 <- openFile "/dev/stdout" ReadWriteMode
--   cc1 <- newClientComm h1
--   cc2 <- newClientComm h2
--   let put1 = putChan cc1
--   let put2 = putChan cc2
--
--   debugChan <- atomically newTChan
--   acceptChan <- atomically newTChan
--
--   _ <- forkIO $ runWithServer (defaultServer mysHandle) (mainLoop acceptChan [cc1, cc2] (return (), debugChan))
--
--
--
--
--   forkIO $ clientOut cc1
--   forkIO $ clientOut cc2
--
--   -- simulate connection of the clients
--   atomically $ writeTChan acceptChan cc1
--   put1 "coco"
--   put1 "coco"
--   put1 "newgame g1"
--   put1 "join g1"
--   put1 "submitRule testRule3 testRuletext \"Legal\""
--
--   atomically $ writeTChan acceptChan cc2
--   put2 "nono"
--   put2 "nono"
--   put2 "join g1"
--   put2 "submitRule testRule4 testRuletext \"eraseRule 3\""
--   --getLine
--   put1 "showpendingactions"
--   --getLine
--
--   put1 "showmypendingactions"
--   --getLine
--   put1 "doaction 1 True"
--   --getLine
--   put1 "showcompletedactions"
--   --getLine
--
--   put1 "showpendingactions"
--   --getLine
--
--   put2 "doaction 1 True"
--   put1 "amendconstitution"
--   --getLine
--
--   put1 "debug read"
--
--   let endrules = [nrVote,
--                   nrImmutable,
--                   NamedRule {rNumber=3, rName ="testRule3", rText="testRuletext", rProposedBy=1, rule = "Legal", rStatus = Active, rejectedBy = Nothing},
--                   NamedRule {rNumber=4, rName ="testRule4", rText="testRuletext", rProposedBy=2, rule = "eraseRule 3", rStatus = Pending, rejectedBy = Nothing}]
--   let endActions = [Action 1 3 (Vote (Konst "Please vote") (Konst 2)) (Just True),
--                     Action 1 3 (Vote (Konst "Please vote") (Konst 1)) (Just True)]
--
--   s <- liftIO $ atomically $ readTChan debugChan
--   --putStrLn $ "Test result:" ++ show (head $ games $ multi s)
--
--   putStrLn $ show (rules $ head $ games $ multi s)
--   putStrLn $ show endrules
--   putStrLn $ show (actionResults $ head $ games $ multi s)
--   putStrLn $ show endActions
--
--
--   return $ (sort $ rules $ head $ games $ multi s) == endrules
--         && (actionResults $ head $ games $ multi s) == endActions
--

-- instances
--instance Arbitrary Rule where
--  arbitrary = sized (arbtree 0 maxkey)
--           where maxkey  = 1000
--
--arbtree :: Int -> Int -> Int -> Gen (Rule)
--arbtree lo hi n
-- | n <= 0        = elements [Legal, Illegal]
-- | lo >= hi      = elements [Legal, Illegal]
-- | otherwise     = do{ i  <- choose (lo,hi)
--                    ; m  <- choose (1,30)
--                     ; let (ml,mr)  | m==(1::Int)= (1,2)
--                                    | m==2       = (2,1)
--                                    | m==3       = (1,1)
--                                    | otherwise  = (2,2)
--                     ; l  <- arbtree lo (i-1) (n `div` ml)
--                     ; r  <- arbtree (i+1) hi (n `div` mr)
--                     ; return (Rand l r)
--                     }

-- Gather all test

allTests = liftM and $ sequence [ruleTestPassed, obsTestPassed, crTestPassed, --actionTestPassed,
                                applyRuleToCurrentRuleSetTest] --, testMulti1, testMulti2] -- must allways be True

