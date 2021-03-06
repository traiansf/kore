module Test.Kore.Repl.Interpreter
    ( test_replInterpreter
    ) where

import Prelude.Kore

import Test.Tasty
    ( TestTree
    )
import Test.Tasty.HUnit
    ( Assertion
    , testCase
    , (@?=)
    )

import Control.Concurrent.MVar
import qualified Control.Lens as Lens
import Control.Monad.Reader
    ( runReaderT
    )
import Control.Monad.Trans.State.Strict
    ( evalStateT
    , runStateT
    )
import Data.Coerce
    ( coerce
    )
import Data.Default
import Data.Generics.Product
import Data.IORef
    ( IORef
    , modifyIORef
    , newIORef
    , readIORef
    )
import Data.List.NonEmpty
    ( NonEmpty (..)
    )
import qualified Data.Map.Strict as Map
import qualified Data.Map.Strict as StrictMap
import qualified Data.Sequence as Seq
import Data.Text
    ( pack
    )

import qualified Kore.Attribute.Axiom as Attribute
import qualified Kore.Builtin.Int as Int
import Kore.Internal.Condition
    ( Condition
    )
import qualified Kore.Internal.Condition as Condition
import Kore.Internal.TermLike
    ( TermLike
    , mkAnd
    , mkBottom_
    , mkElemVar
    , mkElementVariable
    , mkTop_
    )
import qualified Kore.Log as Log
import qualified Kore.Log.Registry as Log
import Kore.Repl.Data
import Kore.Repl.Interpreter
import Kore.Repl.State
import Kore.Rewriting.RewritingVariable
import Kore.Step.RulePattern
import Kore.Step.Simplification.AndTerms
    ( cannotUnifyDistinctDomainValues
    )
import qualified Kore.Step.Simplification.Data as Kore
import Kore.Strategies.Goal
import Kore.Strategies.Verification
    ( verifyClaimStep
    )
import Kore.Syntax.Module
    ( ModuleName (..)
    )
import Kore.Syntax.Variable
import Kore.Unification.Procedure
    ( unificationProcedureWorker
    )
import Kore.Unification.Unify
    ( explainBottom
    )
import Kore.Unparser
    ( unparseToString
    )
import qualified Pretty
import qualified SMT

import Test.Kore.Builtin.Builtin
import Test.Kore.Builtin.Definition
import Test.Kore.Step.Simplification

test_replInterpreter :: [TestTree]
test_replInterpreter =
    [ showUsage                   `tests` "Showing the usage message"
    , help                        `tests` "Showing the help message"
    , step5                       `tests` "Performing 5 steps"
    , step100                     `tests` "Stepping over proof completion"
    , stepf5noBranching           `tests` "Performing 5 foced steps in non-branching proof"
    , stepf100noBranching         `tests` "Stepping over proof completion"
    , makeSimpleAlias             `tests` "Creating an alias with no arguments"
    , trySimpleAlias              `tests` "Executing an existing alias with no arguments"
    , makeAlias                   `tests` "Creating an alias with arguments"
    , aliasOfExistingCommand      `tests` "Create alias of existing command"
    , aliasOfUnknownCommand       `tests` "Create alias of unknown command"
    , recursiveAlias              `tests` "Create alias of unknown command"
    , tryAlias                    `tests` "Executing an existing alias with arguments"
    , unificationFailure          `tests` "Try axiom that doesn't unify"
    , unificationSuccess          `tests` "Try axiom that does unify"
    , forceFailure                `tests` "TryF axiom that doesn't unify"
    , forceSuccess                `tests` "TryF axiom that does unify"
    , proofStatus                 `tests` "Multi claim proof status"
    , logUpdatesState             `tests` "Log command updates the state"
    , showCurrentClaim            `tests` "Showing current claim"
    , showClaim1                  `tests` "Showing the claim at index 1"
    , showClaimByName             `tests` "Showing the claim with the name 0to10Claim"
    , showAxiomByName             `tests` "Showing the axiom with the name add1Axiom"
    , unificationFailureWithName  `tests` "Try axiom by name that doesn't unify"
    , unificationSuccessWithName  `tests` "Try axiom by name that does unify"
    , forceFailureWithName        `tests` "TryF axiom by name that doesn't unify"
    , forceSuccessWithName        `tests` "TryF axiom by name that does unify"
    , proveSecondClaim            `tests` "Starting to prove the second claim"
    , proveSecondClaimByName      `tests` "Starting to prove the second claim\
                                           \ referenced by name"
    ]

showUsage :: IO ()
showUsage =
    let
        axioms  = []
        claim   = emptyClaim
        command = ShowUsage
    in do
        Result { output, continue } <- run command axioms [claim] claim
        output   `equalsOutput` makeAuxReplOutput showUsageMessage
        continue `equals`       Continue

help :: IO ()
help =
    let
        axioms  = []
        claim   = emptyClaim
        command = Help
    in do
        Result { output, continue } <- run command axioms [claim] claim
        output   `equalsOutput` makeAuxReplOutput helpText
        continue `equals`       Continue

step5 :: IO ()
step5 =
    let
        axioms = [ add1 ]
        claim  = zeroToTen
        command = ProveSteps 5
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        output     `equalsOutput`   mempty
        continue   `equals`         Continue
        state      `hasCurrentNode` ReplNode 5

step100 :: IO ()
step100 =
    let
        axioms = [ add1 ]
        claim  = zeroToTen
        command = ProveSteps 100
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        let expectedOutput =
                makeAuxReplOutput $ showStepStoppedMessage 10 NoResult
        output     `equalsOutput`   expectedOutput
        continue   `equals`         Continue
        state      `hasCurrentNode` ReplNode 10

stepf5noBranching :: IO ()
stepf5noBranching =
    let
        axioms = [ add1 ]
        claim  = zeroToTen
        command = ProveStepsF 5
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        output     `equalsOutput`   mempty
        continue   `equals`         Continue
        state      `hasCurrentNode` ReplNode 5

stepf100noBranching :: IO ()
stepf100noBranching =
    let
        axioms = [ add1 ]
        claim  = zeroToTen
        command = ProveStepsF 100
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        let expectedOutput =
                makeAuxReplOutput "Proof completed on all branches."
        output     `equalsOutput`   expectedOutput
        continue   `equals`         Continue
        state      `hasCurrentNode` ReplNode 0

makeSimpleAlias :: IO ()
makeSimpleAlias =
    let
        axioms  = []
        claim   = emptyClaim
        alias   = AliasDefinition { name = "a", arguments = [], command = "help" }
        command = Alias alias
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        output   `equalsOutput` mempty
        continue `equals`       Continue
        state    `hasAlias`     alias

trySimpleAlias :: IO ()
trySimpleAlias =
    let
        axioms  = []
        claim   = emptyClaim
        name    = "h"
        alias   = AliasDefinition { name, arguments = [], command = "help" }
        stateT  = \st -> st { aliases = Map.insert name alias (aliases st) }
        command = TryAlias $ ReplAlias "h" []
    in do
        Result { output, continue } <-
            runWithState command axioms [claim] claim stateT
        output   `equalsOutput` makeAuxReplOutput helpText
        continue `equals` Continue

makeAlias :: IO ()
makeAlias =
    let
        axioms  = []
        claim   = emptyClaim
        alias   = AliasDefinition
                    { name = "c"
                    , arguments = ["n"]
                    , command = "claim n"
                    }
        command = Alias alias
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        output   `equalsOutput` mempty
        continue `equals`       Continue
        state    `hasAlias`     alias

aliasOfExistingCommand :: IO ()
aliasOfExistingCommand =
    let
        axioms  = []
        claim   = emptyClaim
        alias   = AliasDefinition
                    { name = "help"
                    , arguments = ["n"]
                    , command = "claim n"
                    }
        command = Alias alias
    in do
        Result { output, continue } <- run command axioms [claim] claim
        let expectedOutput =
                makeAuxReplOutput . showAliasError $ NameAlreadyDefined
        output   `equalsOutput` expectedOutput
        continue `equals`       Continue

aliasOfUnknownCommand :: IO ()
aliasOfUnknownCommand =
    let
        axioms  = []
        claim   = emptyClaim
        alias   = AliasDefinition
                    { name = "c"
                    , arguments = ["n"]
                    , command = "unknown n"
                    }
        command = Alias alias
    in do
        Result { output, continue } <- run command axioms [claim] claim
        let expectedOutput =
                makeAuxReplOutput . showAliasError $ UnknownCommand
        output   `equalsOutput` expectedOutput
        continue `equals`       Continue

recursiveAlias :: IO ()
recursiveAlias =
    let
        axioms  = []
        claim   = emptyClaim
        alias   = AliasDefinition
                    { name = "c"
                    , arguments = ["n"]
                    , command = "c n"
                    }
        command = Alias alias
    in do
        Result { output, continue } <- run command axioms [claim] claim
        let expectedOutput =
                makeAuxReplOutput . showAliasError $ UnknownCommand
        output   `equalsOutput` expectedOutput
        continue `equals`       Continue

tryAlias :: IO ()
tryAlias =
    let
        axioms  = []
        claim   = emptyClaim
        name    = "c"
        alias   = AliasDefinition
                    { name = "c"
                    , arguments = ["n"]
                    , command = "claim n"
                    }
        stateT  = \st -> st { aliases = Map.insert name alias (aliases st) }
        command = TryAlias $ ReplAlias "c" [SimpleArgument "0"]
    in do
        Result { output, continue } <-
            runWithState command axioms [claim] claim stateT
        output   `equalsOutput` showRewriteRule claim
        continue `equals` Continue

unificationFailure :: IO ()
unificationFailure =
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        impossibleAxiom = mkAxiom one one
        axioms = [ impossibleAxiom ]
        claim = zeroToTen
        command = Try . ByIndex . Left $ AxiomIndex 0
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        expectedOutput <-
            formatUnificationError cannotUnifyDistinctDomainValues one zero
        output `equalsOutput` expectedOutput
        continue `equals` Continue
        state `hasCurrentNode` ReplNode 0

unificationFailureWithName :: IO ()
unificationFailureWithName =
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        impossibleAxiom = mkNamedAxiom one one "impossible"
        axioms = [ impossibleAxiom ]
        claim = zeroToTen
        command = Try . ByName . RuleName $ "impossible"
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        expectedOutput <-
            formatUnificationError cannotUnifyDistinctDomainValues one zero
        output `equalsOutput` expectedOutput
        continue `equals` Continue
        state `hasCurrentNode` ReplNode 0

unificationSuccess :: IO ()
unificationSuccess = do
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        axiom = mkAxiom zero one
        axioms = [ axiom ]
        claim = zeroToTen
        command = Try . ByIndex . Left $ AxiomIndex 0
        expectedOutput = formatUnifiers (Condition.top :| [])

    Result { output, continue, state } <- run command axioms [claim] claim
    output `equalsOutput` expectedOutput
    continue `equals` Continue
    state `hasCurrentNode` ReplNode 0

unificationSuccessWithName :: IO ()
unificationSuccessWithName = do
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        axiom = mkNamedAxiom zero one "0to1"
        axioms = [ axiom ]
        claim = zeroToTen
        command = Try . ByName . RuleName $ "0to1"
        expectedOutput = formatUnifiers (Condition.top :| [])

    Result { output, continue, state } <- run command axioms [claim] claim
    output `equalsOutput` expectedOutput
    continue `equals` Continue
    state `hasCurrentNode` ReplNode 0

forceFailure :: IO ()
forceFailure =
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        impossibleAxiom = mkAxiom one one
        axioms = [ impossibleAxiom ]
        claim = zeroToTen
        command = TryF . ByIndex . Left $ AxiomIndex 0
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        expectedOutput <-
            formatUnificationError cannotUnifyDistinctDomainValues one zero
        output `equalsOutput` expectedOutput
        continue `equals` Continue
        state `hasCurrentNode` ReplNode 0

forceFailureWithName :: IO ()
forceFailureWithName =
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        impossibleAxiom = mkNamedAxiom one one "impossible"
        axioms = [ impossibleAxiom ]
        claim = zeroToTen
        command = TryF . ByName . RuleName $ "impossible"
    in do
        Result { output, continue, state } <- run command axioms [claim] claim
        expectedOutput <-
            formatUnificationError cannotUnifyDistinctDomainValues one zero
        output `equalsOutput` expectedOutput
        continue `equals` Continue
        state `hasCurrentNode` ReplNode 0

forceSuccess :: IO ()
forceSuccess = do
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        axiom = mkAxiom zero one
        axioms = [ axiom ]
        claim = zeroToTen
        command = TryF . ByIndex . Left $ AxiomIndex 0
        expectedOutput = mempty

    Result { output, continue, state } <- run command axioms [claim] claim
    output `equalsOutput` expectedOutput
    continue `equals` Continue
    state `hasCurrentNode` ReplNode 1

forceSuccessWithName :: IO ()
forceSuccessWithName = do
    let
        zero = Int.asInternal intSort 0
        one = Int.asInternal intSort 1
        axiom = mkNamedAxiom zero one "0to1"
        axioms = [ axiom ]
        claim = zeroToTen
        command = TryF . ByName . RuleName $ "0to1"
        expectedOutput = mempty

    Result { output, continue, state } <- run command axioms [claim] claim
    output `equalsOutput` expectedOutput
    continue `equals` Continue
    state `hasCurrentNode` ReplNode 1

proofStatus :: IO ()
proofStatus =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = [add1]
        command = ProofStatus
        expectedProofStatus =
            StrictMap.fromList
                [ (ClaimIndex 0, InProgress [0])
                , (ClaimIndex 1, NotStarted)
                ]
    in do
        Result { output, continue } <-
            run command axioms claims claim
        output `equalsOutput` makeAuxReplOutput (showProofStatus expectedProofStatus)
        continue `equals` Continue

showCurrentClaim :: IO ()
showCurrentClaim =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = []
        command = ShowClaim Nothing
        expectedCindex = ClaimIndex 0
    in do
        Result { output, continue } <-
            run command axioms claims claim
        equalsOutput
            output
            $ makeAuxReplOutput (showCurrentClaimIndex expectedCindex)
                <> (makeKoreReplOutput . unparseToString $ zeroToTen)
        continue `equals` Continue

showClaim1 :: IO ()
showClaim1 =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = []
        command = ShowClaim (Just . Left . ClaimIndex $ 1)
        expectedClaim = emptyClaim
    in do
        Result { output, continue } <-
            run command axioms claims claim
        output `equalsOutput` showRewriteRule expectedClaim
        continue `equals` Continue

showClaimByName :: IO ()
showClaimByName =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = []
        command = ShowClaim (Just . Right . RuleName $ "0to10Claim")
        expectedClaim = zeroToTen
    in do
        Result { output, continue } <-
            run command axioms claims claim
        output `equalsOutput` showRewriteRule expectedClaim
        continue `equals` Continue

showAxiomByName :: IO ()
showAxiomByName =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = [add1]
        command = ShowAxiom (Right . RuleName $ "add1Axiom")
        expectedAxiom = add1
    in do
        Result { output, continue } <-
            run command axioms claims claim
        output `equalsOutput` showRewriteRule expectedAxiom
        continue `equals` Continue

logUpdatesState :: IO ()
logUpdatesState = do
    let
        axioms  = []
        claim   = emptyClaim
        options =
            def
                { Log.logLevel = Log.Info
                , Log.logEntries =
                    Map.keysSet . Log.typeToText $ Log.registry
                }
        command = Log options
    Result { output, continue, state } <-
        run command axioms [claim] claim
    output   `equalsOutput` mempty
    continue `equals`     Continue
    state `hasLogging` options

proveSecondClaim :: IO ()
proveSecondClaim =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = [add1]
        indexOrName = Left . ClaimIndex $ 1
        command = Prove indexOrName
        expectedClaimIndex = ClaimIndex 1
    in do
        Result { output, continue, state } <-
            run command axioms claims claim
        output `equalsOutput` makeAuxReplOutput (showClaimSwitch indexOrName)
        state `hasCurrentClaimIndex` expectedClaimIndex
        continue `equals` Continue

proveSecondClaimByName :: IO ()
proveSecondClaimByName =
    let
        claims = [zeroToTen, emptyClaim]
        claim = zeroToTen
        axioms = [add1]
        indexOrName = Right . RuleName $ "emptyClaim"
        command = Prove indexOrName
        expectedClaimIndex = ClaimIndex 1
    in do
        Result { output, continue, state } <-
            run command axioms claims claim
        output `equalsOutput` makeAuxReplOutput (showClaimSwitch indexOrName)
        state `hasCurrentClaimIndex` expectedClaimIndex
        continue `equals` Continue

add1 :: Axiom
add1 =
    mkNamedAxiom n plusOne "add1Axiom"
  where
    one     = Int.asInternal intSort 1
    n       = mkElemVar $ mkElementVariable "x" intSort
    plusOne = n `addInt` one

zeroToTen :: Claim
zeroToTen =
    OnePath . coerce
    $ claimWithName zero (mkAnd mkTop_ ten) "0to10Claim"
  where
    zero = Int.asInternal intSort 0
    ten  = Int.asInternal intSort 10

emptyClaim :: Claim
emptyClaim =
    OnePath . coerce
    $ claimWithName mkBottom_ (mkAnd mkTop_ mkBottom_) "emptyClaim"

mkNamedAxiom
    :: TermLike VariableName
    -> TermLike VariableName
    -> String
    -> Axiom
mkNamedAxiom left right name =
    rulePattern left right
    & Lens.set (field @"attributes" . typed @Attribute.Label) label
    & RewriteRule
    & mkRewritingRule
    & coerce
  where
    label = Attribute.Label . pure $ pack name

claimWithName
    :: TermLike VariableName
    -> TermLike VariableName
    -> String
    -> RewriteRule VariableName
claimWithName left right name =
    rulePattern left right
    & Lens.set (field @"attributes" . typed @Attribute.Label) label
    & RewriteRule
  where
    label = Attribute.Label . pure $ pack name

mkAxiom
    :: TermLike VariableName
    -> TermLike VariableName
    -> Axiom
mkAxiom left right =
    rulePattern left right
    & RewriteRule
    & mkRewritingRule
    & coerce

run :: ReplCommand -> [Axiom] -> [Claim] -> Claim -> IO Result
run command axioms claims claim =
    runWithState command axioms claims claim id

runWithState
    :: ReplCommand
    -> [Axiom]
    -> [Claim]
    -> Claim
    -> (ReplState -> ReplState)
    -> IO Result
runWithState command axioms claims claim stateTransformer = do
    let logger = mempty
    output <- newIORef (mempty :: ReplOutput)
    mvar <- newMVar logger
    let state = stateTransformer $ mkState axioms claims claim
    let config = mkConfig mvar
    (c, s) <-
        flip Log.runLoggerT (Log.swappableLogger mvar)
        $ liftSimplifier
        $ flip runStateT state
        $ flip runReaderT config
        $ replInterpreter0
            (PrintAuxOutput . modifyAuxOutput $ output)
            (PrintKoreOutput . modifyKoreOutput $ output)
            command
    output' <- readIORef output
    return $ Result output' c s
  where
    liftSimplifier = SMT.runSMT SMT.defaultConfig . Kore.runSimplifier testEnv

    modifyAuxOutput :: IORef ReplOutput -> String -> IO ()
    modifyAuxOutput ref s = modifyIORef ref (appReplOut . AuxOut $ s)

    modifyKoreOutput :: IORef ReplOutput -> String -> IO ()
    modifyKoreOutput ref s = modifyIORef ref (appReplOut . KoreOut $ s)

data Result = Result
    { output   :: ReplOutput
    , continue :: ReplStatus
    , state    :: ReplState
    }

equals :: (Eq a, Show a) => a -> a -> Assertion
equals = (@?=)

equalsOutput :: ReplOutput -> ReplOutput -> Assertion
equalsOutput actual expected =
    actual @?= expected

hasCurrentNode :: ReplState -> ReplNode -> IO ()
hasCurrentNode st n = do
    node st `equals` n
    graphNode <- evalStateT (getTargetNode justNode) st
    graphNode `equals` justNode
  where
    justNode = Just n

hasAlias :: ReplState -> AliasDefinition -> IO ()
hasAlias st alias@AliasDefinition { name } =
    let
        aliasMap = aliases st
        actual   = name `Map.lookup` aliasMap
    in
        actual `equals` Just alias

hasLogging
    :: ReplState
    -> Log.KoreLogOptions
    -> IO ()
hasLogging st expectedLogging =
    let
        actualLogging = koreLogOptions st
    in
        actualLogging `equals` expectedLogging

hasCurrentClaimIndex :: ReplState -> ClaimIndex -> IO ()
hasCurrentClaimIndex st expectedClaimIndex =
    let
        actualClaimIndex = claimIndex st
    in
        actualClaimIndex `equals` expectedClaimIndex

tests :: IO () -> String -> TestTree
tests = flip testCase

mkState
    :: [Axiom]
    -> [Claim]
    -> Claim
    -> ReplState
mkState axioms claims claim =
    ReplState
        { axioms         = axioms
        , claims         = claims
        , claim          = claim
        , claimIndex     = ClaimIndex 0
        , graphs         = Map.singleton (ClaimIndex 0) graph'
        , node           = ReplNode 0
        , commands       = Seq.empty
        , omit           = mempty
        , labels         = Map.singleton (ClaimIndex 0) Map.empty
        , aliases        = Map.empty
        , koreLogOptions = def
        }
  where
    graph' = emptyExecutionGraph claim

mkConfig
    :: MVar (Log.LogAction IO Log.ActualEntry)
    -> Config Simplifier
mkConfig logger =
    Config
        { stepper     = stepper0
        , unifier     = unificationProcedureWorker
        , logger
        , outputFile  = OutputFile Nothing
        , mainModuleName = ModuleName "TEST"
        }
  where
    stepper0
        :: Claim
        -> [Claim]
        -> [Axiom]
        -> ExecutionGraph Axiom
        -> ReplNode
        -> Simplifier (ExecutionGraph Axiom)
    stepper0 claim' claims' axioms' graph (ReplNode node) =
        verifyClaimStep claim' claims' axioms' graph node

formatUnificationError
    :: Pretty.Doc ()
    -> TermLike VariableName
    -> TermLike VariableName
    -> IO ReplOutput
formatUnificationError info first second = do
    res <- runSimplifier testEnv . runUnifierWithExplanation $ do
        explainBottom info first second
        empty
    return $ formatUnificationMessage res

formatUnifiers :: NonEmpty (Condition VariableName) -> ReplOutput
formatUnifiers = formatUnificationMessage . Right
