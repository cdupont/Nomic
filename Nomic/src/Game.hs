
{-# LANGUAGE StandaloneDeriving, GADTs #-}

-- | This module implements Game management.
-- a game is a set of rules, and results of actions made by players (usually vote results)
-- the module manages the effects of rules over each others.
module Game where

import Rule
import Control.Monad.State
import Text.Printf
import Data.List
import Utils
import Interpret
import Observable
import Data.Either
import Action
import Control.Applicative
import Comm
import Safe
import Control.Arrow
import NamedRule


data PlayerInfo = PlayerInfo { playerNumber :: PlayerNumber,
                               playerName :: String}
                               deriving (Eq)

instance Ord PlayerInfo where
   h <= g = (playerNumber h) <= (playerNumber g)
							   		

type PlayerList = [PlayerInfo]

type GameName = String

-- | The state of the game:
data Game = Game { gameName :: GameName,
                   rules :: RuleSet,
                   actionResults :: Actions,
                   players :: PlayerList}

initialGame name = Game { gameName = name,
                          rules = initialRuleSet,
                          actionResults = [],
                          players = []}

defaultGame = Game "Default Game" defaultRS []
defaultGameWithPropRule = Game "Default Game" defaultRSWithPropRule []



-- | Allow to pass around the state of the game while making IO on a specified Handle:
type GameState = StateT Game Comm ()

type GameStateWith a = StateT Game Comm a

-- | An helper function that makes it very clear how to use the state transformer GameState.
runWithGame :: Game -> GameState -> Comm Game
runWithGame = flip execStateT


-- | This function will propose all pending rules for addition to the constitution.               
proposeAllPendings :: GameState
proposeAllPendings = do
    prs <- gets pendingRules
    case prs of
       [] -> say "No pending rules"
       _:_ -> sequence_ $ map proposeRule (sort prs)


-- | This function will proposes a rule for addition to the constitution.
proposeRule :: NamedRule -> GameState 
proposeRule nr = do
   say $ "\nYour rule: \n" ++ (show nr)
   gs <- get
   say $ "is going to be evaluated against the current legislation: \n\n" ++ (showRS $ activeRules gs) ++ "\n"
   -- try to amend the current ruleset with the new rule.
   amend nr
   newgs <- get    
   if newgs == gs 
       then say $ "no changes to the legislation. \n"
       else say $ "new legislation: \n" ++ (showRS $ activeRules newgs) ++ "\n"



-- | this function tests whereas a rule is legal according to current legislation.
-- If legal, we return Right Nothing. If illegal, we return Just the number of the rule that illegalised our rule.
-- Else, we return remaining actions in Left.
isLegal :: NamedRule -> GameStateWith (Either Actions (Maybe RuleNumber))
isLegal nr = do
   lega <- legalityList nr
   case concat $ lefts $ map fst lega of
      a:as -> return $ Left $ (a:as)
      []   -> return $ Right $ lookup (Right False) lega


-- | this function tests a rule against a legislation.
-- it returns the result for every rules of the constitution, along with the rules number.
legalityList :: NamedRule -> GameStateWith [(Either Actions Bool, RuleNumber)]
legalityList nr = do
   ar <- gets activeRules
   legals <- mapM (flip isRuleLegal nr) ar
   return $ zip legals (map rNumber ar)


-- | this function apply the rule to the current legislation.
-- this mean applying the rule to each rules in the constitution.
-- some rules from the constitution may be declared illegal, and suppressed.
applyTo :: NamedRule -> GameState
applyTo nr = do
        ars <- gets activeRules
        legals <- applyTo' nr ars
        let rejectedList = map fst $ filter (not.snd) legals
        case rejectedList of
            _:_ -> say $ "The new rule declares the following rules as illegal: " ++ (show $ map rNumber rejectedList)
                     ++ ". They are withdrawn from the constitution.\n"
            [] -> say "The new rule doesn't change the constitution.\n"
        let rejectedList' = map (\mynr -> mynr{rStatus = Suppressed, rejectedBy = Just $ rNumber nr}) rejectedList
        mapM_ modifyRule rejectedList'


applyTo' :: NamedRule -> RuleSet -> GameStateWith [(NamedRule, Bool)]
applyTo' testing rs = do
   legals <- applyTo'' testing rs
   return $ map (second getValue) legals

getValue :: Either Actions Bool -> Bool
getValue e = case e of
   Right b -> b
   Left _ -> True    --TODO: repair. For now pending votes are Trued in execution.                                                   

-- | apply a rule to a set of rules. Return whereas the given rules are legal or not to the former.
applyTo'' :: NamedRule -> RuleSet -> GameStateWith [(NamedRule, Either Actions Bool)]
applyTo'' testing rs = do
   -- test each rule.
   legals <- mapM (isRuleLegal testing) rs
   return $ zip rs $ legals


-- | Play a rule. It may be added to the current ruleset if legal!
-- it may then modify the ruleset.
amend :: NamedRule -> GameState
amend nr = do
   say "Checking your rule against the current legislation...\n"
   legal <- isLegal nr
   case legal of
      Right Nothing -> do
         say "Rule legal. It is added to the constitution:\n"
         -- the rule become official: it is added to the rule set
         modifyRule nr{rStatus = Active}
         get >>= say  .  showRS  .  activeRules
         say "Your rule is beeing executed over the legislation:\n"
         -- the new rule is then applyed to the whole active ruleset. This way the new rule can modify the active ruleset.
         applyTo nr

      Right (Just r) -> do
         say $ "Your rule is illegal against rule n#" ++ show r ++ "! It is rejected.\n"
         modifyRule nr{rStatus = Rejected, rejectedBy = Just r}

      Left as -> do
         sas <- showActions as
         say $ "Their are remaining actions left to complete before beeing able to amend the constitution:\n"
            ++ sas


-- | Finds the corresponding game in the multistate and replaces it.
modifyRule :: NamedRule -> GameState
modifyRule nr = do
   rs <- gets rules
   case find (\mynr -> rNumber nr == rNumber mynr) rs of
      Nothing -> error "modifyRule: No rule by that number"
      Just oldnr -> modify (\game -> game { rules = replace oldnr nr rs})



--accessors

activeRules :: Game -> RuleSet
activeRules = filter (\(NamedRule {rStatus=rs}) -> rs==Active)  .  rules

pendingRules :: Game -> RuleSet
pendingRules = filter (\(NamedRule {rStatus=rs}) -> rs==Pending)  .  rules

rejectedRules :: Game -> RuleSet
rejectedRules = filter (\(NamedRule {rStatus=rs}) -> rs==Rejected)  .  rules

suppressedRules :: Game -> RuleSet
suppressedRules = filter (\(NamedRule {rStatus=rs}) -> rs==Suppressed)  .  rules

allRules :: Game -> RuleSet
allRules = liftM2 (++)  activeRules pendingRules

currentlyProposedRule :: Game -> Maybe NamedRule
currentlyProposedRule = headMay . pendingRules



-- Actions

-- | This function lists all pending actions to do         
pendingActions :: GameStateWith Actions
pendingActions = do
   prs <- gets pendingRules
   ars <- gets activeRules
   --fs <- mapM isRuleLegal (sort prs)
   legals <- mapM (\testing -> mapM (\tested -> isRuleLegal testing tested) (sort prs)) (sort ars)  --TODO refactor
   return $ concat $ lefts $ concat legals


-- | This function lists pending actions of a player
playersPendingActions :: PlayerNumber -> GameStateWith Actions
playersPendingActions pn = do
   pas <- pendingActions
   filterM (isPlayersaction pn) pas


-- | This function tells whereas an action is for a player
isPlayersaction :: PlayerNumber -> Action -> GameStateWith Bool
isPlayersaction pn (Action testing tested (Vote _ o) _) = do
   epn <- evalObs' o tested testing
   case epn of
      Right mpn -> return $ mpn == pn
      Left _    -> return False

isPlayersaction _ _ = error "isPlayersaction: Not an action"

-- | Show an action
showAction :: Action -> GameStateWith String
showAction (Action testing tested (Vote (Konst s) o) result) = do
   evalo <- evalObs' o tested testing
   let pn = case evalo of
               Right n -> show n
               Left _ -> "unresolved action" --showActions g as
   return $ "Evaluation of rule #" ++ (show tested) ++ " by rule #" ++ (show testing) ++ ", action for player " ++ pn ++ ": " ++ s ++ "\n"
            ++ maybe "" (\b -> "Action result: " ++ (show b) ++ "\n") result


showAction _ = error "showAction: try to show an action that is not vote."

-- | Show actions
showActions :: Actions -> GameStateWith String
showActions as = do
   sas <- mapM showAction as
   case sas of
      _:_ -> return $ concat $ zipWith (\n a -> show n ++  ". " ++ a) [1..] sas
      [] -> return "No actions"



-- Evaluator on rules

-- | This type is usefull for rules evaluation:
-- it allows modifications of a game
-- it allows IO on players handles
-- its return type is either the value calculated, or a list of remaining actions.
type Evaluator a = GameStateWith (Either Actions a)

-- | Combined lifters for Evaluator
liftE  = liftM  . liftA
liftE2 = liftM2 . liftA2
liftE3 = liftM3 . liftA3


evaluate :: Evaluator a -> Game -> Comm (Either Actions a)
evaluate = evalStateT

-- | tests the legality of a rule against another.
-- return: either the legality of the tested rule, or remaining actions.
isRuleLegal :: NamedRule -> NamedRule -> Evaluator Bool
isRuleLegal testing tested = do
   testing' <- lift $ readNamedRule testing
   isRuleLegal' testing' tested (rNumber testing)


-- | tests the legality of a rule against another.
-- arguments: testing rule, tested rule, number of the testing rule, game.
-- return: either the legality of the tested rule, or remaining actions.
isRuleLegal' :: Rule -> NamedRule -> RuleNumber -> Evaluator Bool
isRuleLegal' (MustBeEgalTo r) nr _ = do
   myr <- lift $ readNamedRule nr
   return $ pure $ r == myr
isRuleLegal' Legal _ _             = return $ pure True
isRuleLegal' Illegal _ _           = return $ pure False
isRuleLegal' (Rnot a) nr sn        = liftE  not   (isRuleLegal' a nr sn)
isRuleLegal' (a `Rand` b) nr sn    = liftE2 (&&)  (isRuleLegal' a nr sn) (isRuleLegal' b nr sn)
isRuleLegal' (a `Ror` b) nr sn     = liftE2 (||)  (isRuleLegal' a nr sn) (isRuleLegal' b nr sn)
isRuleLegal' (Cond o r1 r2) nr sn  = liftE3 (if3) (evalObs o nr sn) (isRuleLegal' r1 nr sn) (isRuleLegal' r2 nr sn)
     
isRuleLegal' (OfficialRule n) nr sn = do
   morn <- getOfficialRuleNumber n
   case morn of
      Just orn -> isRuleLegal' orn nr sn
      Nothing -> return $ pure True  --TODO check if the number is false, the rule says always yes...
   
isRuleLegal' (TestRuleOver r) nr sn = do
   nr' <- lift $ readNamedRule nr
   isRuleLegal' nr' (defaultNRWith r) sn

defaultNRWith :: Rule -> NamedRule
defaultNRWith r = NamedRule {rNumber=0, rName ="", rText="", rProposedBy=0, rule = show r, rStatus = Pending, rejectedBy = Nothing}

-- | Get an official rule by its number.
getOfficialRuleNumber :: RuleNumber -> GameStateWith (Maybe Rule)
getOfficialRuleNumber n = do
   ar <- gets activeRules
   let mnr = find (\NamedRule {rNumber=m} -> m == n) ar
   case mnr of
      Just nr -> do
         r <- lift $ readNamedRule nr
         return $ Just r
      Nothing -> return Nothing

-- | query the player to enter his rule.
enterRule' :: PlayerNumber -> RuleNumber -> Comm NamedRule
enterRule' nP num = do
   putCom $ "Enter the name of your rule:"
   name <- getCom
   putCom $ "Enter a description of your rule:"
   text <- getCom
   putCom $ "Enter the code of your rule:"
   rule <- getCom
   return $ NamedRule {rNumber = num,
                       rName = name,
                       rText = text,
                       rProposedBy = nP,
                       rule = rule,
                       rStatus = Pending,
                       rejectedBy = Nothing}

-- evaluator on observable

-- | Evaluate an Observable. We pass it the tested rule, its own rule number and the state of the game.
-- it returns either the value of the observable if it can, or the actions necessary to complete to reach this value.
evalObs' :: Obs a -> RuleNumber -> RuleNumber -> Evaluator a
evalObs' o tested testing = do
   g <- get
   case findNamedRule tested (rules g) of
      Just nr -> evalObs o nr testing
      Nothing -> error "evalObs': can't find tested named rule. Shouldn't have happened."


-- | Evaluate an Observable. We pass it the tested rule, its own rule number and the state of the game.
-- it returns either the value of the observable if it can, or the actions necessary to complete to reach this value.
evalObs :: Obs a -> NamedRule -> RuleNumber -> Evaluator a
evalObs ProposedBy (NamedRule {rProposedBy=proposedBy}) _ = return $ pure proposedBy
evalObs RuleNumber (NamedRule {rNumber=rNumber})        _ = return $ pure rNumber
evalObs Official   (NamedRule {rNumber=rn})             _ = return . pure . (isOfficial rn) =<< get  
evalObs SelfNumber _  sn                                  = return $ pure sn
evalObs (Konst a)  _ _                                    = return $ pure a
evalObs (Not a)     nr sn = liftE  not   (evalObs a nr sn)
evalObs (Plus a b)  nr sn = liftE2 (+)   (evalObs a nr sn) (evalObs b nr sn)
evalObs (Minus a b) nr sn = liftE2 (-)   (evalObs a nr sn) (evalObs b nr sn) 
evalObs (Time a b)  nr sn = liftE2 (*)   (evalObs a nr sn) (evalObs b nr sn)
evalObs (And a b)   nr sn = liftE2 (&&)  (evalObs a nr sn) (evalObs b nr sn)  
evalObs (Or a b)    nr sn = liftE2 (||)  (evalObs a nr sn) (evalObs b nr sn)
evalObs (Equ a b)   nr sn = liftE2 (==)  (evalObs a nr sn) (evalObs b nr sn)
evalObs (If a b c)  nr sn = liftE3 (if3) (evalObs a nr sn) (evalObs b nr sn) (evalObs c nr sn) 

evalObs v@(Vote _ o) nr sn = do g <- get
                                evalres <- (evalObs o nr sn)
                                return $ case findActionResult v nr sn (actionResults g) of  --TODO: vérifications d'usage: nb players etc.
                                   Just r -> Right $ maybe (error "Action result should be fulfilled at this stage.") id (result r)
                                   Nothing -> (Left $ [(Action sn (rNumber nr) v Nothing)]) <*> evalres
 
if3 a b c = if a then b else c



-- evalObs (OpBi "enumFromTo" a b) g r = 


-- | search the rule number amount official rules
isOfficial :: RuleNumber -> Game -> Bool
isOfficial rn g = not . null $ filter (\(NamedRule {rNumber=rNumberOff}) -> rNumberOff == rn) $ activeRules g


-- Instances

deriving instance Eq Game 


instance Show Game where
   show (Game name rules ars pls) = 
      printf "Game name: %s \n%s\n Completed actions: %s\n Players: %s" name (showRS rules) (show ars) (show pls)

instance Ord Game where
   compare (Game name1 _ _ _) (Game name2 _ _ _) = compare name1 name2
      
instance Show PlayerInfo where
   show (PlayerInfo { playerNumber = pn,
                      playerName = name})  
      = show pn ++ ": " ++ name
