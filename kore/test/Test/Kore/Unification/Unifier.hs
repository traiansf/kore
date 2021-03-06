module Test.Kore.Unification.Unifier
    ( test_unification
    , test_unsupportedConstructs
    , test_evaluated
    ) where

import Prelude.Kore

import Test.Tasty

import Control.Exception
    ( ErrorCall (ErrorCall)
    , catch
    , evaluate
    )
import qualified Data.Bifunctor as Bifunctor
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty
    ( NonEmpty ((:|))
    )
import qualified Data.Map.Strict as Map
import Data.Text
    ( Text
    )

import qualified Kore.Internal.Condition as Condition
import qualified Kore.Internal.MultiOr as MultiOr
import qualified Kore.Internal.SideCondition as SideCondition
    ( top
    , topTODO
    )
import Kore.Step.Simplification.Data
    ( Env (..)
    , runSimplifier
    )
import qualified Kore.Step.Simplification.Not as Not
import qualified Kore.Step.Simplification.Pattern as Pattern
import Kore.Step.Simplification.Simplify
    ( BuiltinAndAxiomSimplifierMap
    , MonadSimplify
    )
import qualified Kore.Step.Simplification.SubstitutionSimplifier as SubstitutionSimplifier
import Kore.Unification.Error
import Kore.Unification.Procedure
import qualified Kore.Unification.SubstitutionSimplifier as Unification
import qualified Kore.Unification.UnifierT as Monad.Unify
import Kore.Unparser
import qualified Pretty

import Test.Kore
import Test.Kore.Internal.Pattern as Pattern
import Test.Kore.Internal.Predicate
    ( TestPredicate
    )
import qualified Test.Kore.Internal.Predicate as Predicate
import Test.Kore.Internal.Substitution
    ( TestAssignment
    )
import qualified Test.Kore.Internal.Substitution as Substitution
import qualified Test.Kore.Internal.TermLike as TermLike
import Test.Kore.Step.MockSymbols
    ( MockElementVariable
    , pattern MockElementVariable
    )
import qualified Test.Kore.Step.MockSymbols as Mock
import Test.Kore.Variables.V
import Test.Kore.Variables.W
import Test.SMT
    ( runNoSMT
    )
import Test.Tasty.HUnit.Ext

var :: Text -> Sort -> MockElementVariable
var name variableSort =
    MockElementVariable (testId name) mempty variableSort

a1, a2, a3, a4, a5 :: TestTerm
a1 = Mock.c
a2 = TermLike.markSimplified Mock.functional00
a3 = Mock.constr00
a4 = TermLike.markSimplified Mock.functionalInjective00
a5 = TermLike.markSimplified Mock.cf

a :: TestTerm
a = Mock.a

b :: TestTerm
b = Mock.b

f :: TestTerm -> TestTerm
f = Mock.constr10

ef :: TestTerm -> TestTerm -> TestTerm -> TestTerm
ef = Mock.functionalConstr30

eg, eh :: TestTerm -> TestTerm
eg = Mock.functionalConstr10
eh = Mock.functionalConstr11

nonLinF :: TestTerm -> TestTerm -> TestTerm
nonLinF = Mock.functionalConstr20

nonLinG :: TestTerm -> TestTerm
nonLinG = Mock.functionalConstr12

nonLinA, nonLinX, nonLinY :: TestTerm
nonLinA = Mock.d
nonLinX = mkElemVar Mock.x
nonLinY = mkElemVar Mock.y

expBin :: TestTerm -> TestTerm -> TestTerm
expBin = Mock.functionalConstr21

expA, expX, expY :: TestTerm
expA = mkElemVar $ var "a" Mock.testSort
expX = mkElemVar $ var "x" Mock.testSort
expY = mkElemVar $ var "y" Mock.testSort

ex1, ex2, ex3, ex4 :: TestTerm
ex1 = mkElemVar $ var "ex1" Mock.testSort
ex2 = mkElemVar $ var "ex2" Mock.testSort
ex3 = mkElemVar $ var "ex3" Mock.testSort
ex4 = mkElemVar $ var "ex4" Mock.testSort


dv1, dv2 :: TestTerm
dv1 =
    mkDomainValue DomainValue
        { domainValueSort = Mock.testSort
        , domainValueChild = mkStringLiteral "dv1"
        }
dv2 =
    mkDomainValue DomainValue
        { domainValueSort = Mock.testSort
        , domainValueChild = mkStringLiteral "dv2"
        }

testEnv :: MonadSimplify simplifier => Env simplifier
testEnv = Mock.env

unificationProblem :: UnificationTerm -> UnificationTerm -> TestTerm
unificationProblem (UnificationTerm term1) (UnificationTerm term2) =
    mkAnd term1 term2

type Substitution = [(Text, TestTerm)]

unificationSubstitution :: Substitution -> [ TestAssignment ]
unificationSubstitution = map trans
  where
    trans (v, p) =
        Substitution.assign (Mock.makeSomeVariable v (termLikeSort p)) p

unificationResult :: UnificationResult -> TestPattern
unificationResult
    UnificationResult { term, substitution, predicate }
  =
    Conditional
        { term
        , predicate
        , substitution =
            Substitution.unsafeWrapFromAssignments
                $ unificationSubstitution substitution
        }

newtype UnificationTerm = UnificationTerm TestTerm

instance Unparse UnificationTerm where
    unparse (UnificationTerm term) = unparse term
    unparse2 (UnificationTerm term) = unparse2 term

data UnificationResult =
    UnificationResult
        { term :: TestTerm
        , substitution :: Substitution
        , predicate :: TestPredicate
        }

simplifyAnds
    :: Monad.Unify.MonadUnify unifier
    => NonEmpty TestTerm
    -> unifier TestPattern
simplifyAnds =
    SubstitutionSimplifier.simplifyAnds
        (Unification.unificationMakeAnd Not.notSimplifier)
        SideCondition.top

andSimplifySuccess
    :: HasCallStack
    => UnificationTerm
    -> UnificationTerm
    -> [UnificationResult]
    -> Assertion
andSimplifySuccess term1 term2 results = do
    let expect = map unificationResult results
    Right subst' <-
        runNoSMT
        $ runSimplifier testEnv
        $ Monad.Unify.runUnifierT Not.notSimplifier
        $ simplifyAnds (unificationProblem term1 term2 :| [])
    assertEqual (message expect subst') expect subst'
  where
    message expected actual =
        (show . Pretty.vsep)
            [ "Unifying term:"
            , Pretty.indent 4 (unparse term1)
            , "with term:"
            , Pretty.indent 4 (unparse term2)
            , "expected="
            , Pretty.indent 4 (Foldable.fold (map unparse expected))
            , "actual="
            , Pretty.indent 4 (Foldable.fold (map unparse actual))
            ]

andSimplifyFailure
    :: HasCallStack
    => UnificationTerm
    -> UnificationTerm
    -> UnificationError
    -> Assertion
andSimplifyFailure term1 term2 err = do
    let expect :: Either UnificationError TestPattern
        expect = Left err
    actual <-
        runNoSMT
        $ runSimplifier testEnv
        $ Monad.Unify.runUnifierT Not.notSimplifier
        $ simplifyAnds (unificationProblem term1 term2 :| [])
    assertEqual "" (show expect) (show actual)

andSimplifyException
    :: HasCallStack
    => String
    -> UnificationTerm
    -> UnificationTerm
    -> String
    -> TestTree
andSimplifyException message term1 term2 exceptionMessage =
    testCase message (catch test handler)
    where
        test = do
            assignment <-
                runNoSMT $ runSimplifier testEnv
                $ Monad.Unify.runUnifierT Not.notSimplifier
                $ simplifyAnds (unificationProblem term1 term2 :| [])
            _ <- evaluate assignment
            assertFailure "This evaluation should fail"
        handler (ErrorCall s) = assertEqual "" exceptionMessage s

unificationProcedureSuccessWithSimplifiers
    :: HasCallStack
    => TestName
    -> BuiltinAndAxiomSimplifierMap
    -> UnificationTerm
    -> UnificationTerm
    -> [([TestAssignment], TestPredicate)]
    -> TestTree
unificationProcedureSuccessWithSimplifiers
    message
    axiomIdToSimplifier
    (UnificationTerm term1)
    (UnificationTerm term2)
    expect
  =
    testCase message $ do
        let mockEnv = testEnv { simplifierAxioms = axiomIdToSimplifier }
        Right results <-
            unificationProcedureWorker
                SideCondition.topTODO
                term1
                term2
            & Monad.Unify.runUnifierT Not.notSimplifier
            & runSimplifier mockEnv
            & runNoSMT
        let
            normalize :: Condition VariableName -> ([TestAssignment], TestPredicate)
            normalize Conditional { substitution, predicate } =
                (Substitution.unwrap substitution, predicate)
        assertEqual ""
            expect
            (map normalize results)

unificationProcedureSuccess
    :: HasCallStack
    => TestName
    -> UnificationTerm
    -> UnificationTerm
    -> [(Substitution, TestPredicate)]
    -> TestTree
unificationProcedureSuccess message term1 term2 substPredicate =
    unificationProcedureSuccessWithSimplifiers
        message
        Map.empty
        term1
        term2
        expect
  where
    expect :: [([TestAssignment], TestPredicate)]
    expect =
        map (Bifunctor.first unificationSubstitution) substPredicate

test_unification :: [TestTree]
test_unification =
    [ testCase "Constant" $
        andSimplifySuccess
            (UnificationTerm a)
            (UnificationTerm a)
            [ UnificationResult
                { term = a
                , substitution = []
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "Variable" $
        andSimplifySuccess
            (UnificationTerm (mkElemVar Mock.x))
            (UnificationTerm a)
            [ UnificationResult
                { term = a
                , substitution = [("x", a)]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "one level" $
        andSimplifySuccess
            (UnificationTerm (f (mkElemVar Mock.x)))
            (UnificationTerm (f a))
            [ UnificationResult
                { term = f a
                , substitution = [("x", a)]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "equal non-constructor patterns" $
        andSimplifySuccess
            (UnificationTerm a2)
            (UnificationTerm a2)
            [ UnificationResult
                { term = a2
                , substitution = []
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "variable + non-constructor pattern" $
        andSimplifySuccess
            (UnificationTerm a2)
            (UnificationTerm (mkElemVar Mock.x))
            [ UnificationResult
                { term = a2
                , substitution = [("x", a2)]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "https://basics.sjtu.edu.cn/seminars/c_chu/Algorithm.pdf slide 3"
        $ andSimplifySuccess
            (UnificationTerm (ef ex1 (eh ex1) ex2))
            (UnificationTerm (ef (eg ex3) ex4 ex3))
            [ UnificationResult
                { term = ef (eg ex3) (eh ex1) ex3
                , substitution =
                    [ ("ex1", eg ex3)
                    , ("ex2", ex3)
                    , ("ex4", eh (eg ex3))
                    ]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "f(g(X),X) = f(Y,a) https://en.wikipedia.org/wiki/Unification_(computer_science)#Examples_of_syntactic_unification_of_first-order_terms" $
        andSimplifySuccess

            (UnificationTerm (nonLinF (nonLinG nonLinX) nonLinX))
            (UnificationTerm (nonLinF nonLinY nonLinA))
            [ UnificationResult
                { term = nonLinF (nonLinG nonLinX) nonLinA
                , substitution =
                    [ ("x", nonLinA)
                    , ("y", nonLinG nonLinA)
                    ]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , testCase "times(times(a, y), (mkElemVar Mock.x)) = times(x, times(y, a))"
        $ andSimplifySuccess
            (UnificationTerm (expBin (expBin expA expY) expX))
            (UnificationTerm (expBin expX (expBin expY expA)))
            [ UnificationResult
                { term = expBin (expBin expA expY) (expBin expY expA)
                , substitution =
                    [ ("a", expY)
                    , ("x", expBin expY expY)
                    ]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , unificationProcedureSuccess
        "times(x, g(x)) = times(a, a) -- cycle bottom"
        (UnificationTerm (expBin expX (eg expX)))
        (UnificationTerm (expBin expA expA))
        []
    , unificationProcedureSuccess
        "times(times(a, y), (mkElemVar Mock.x)) = times(x, times(y, a))"
        (UnificationTerm (expBin (expBin expA expY) expX))
        (UnificationTerm (expBin expX (expBin expY expA)))
        [   (   [ ("a", expY)
                , ("x", expBin expY expY)
                ]
            , Predicate.makeTruePredicate_
            )
        ]
    , unificationProcedureSuccess
        "Unifying two non-ctors results in equals predicate"
        (UnificationTerm a2)
        (UnificationTerm a4)
        [ ([], makeEqualsPredicate_ a2 a4) ]
    , unificationProcedureSuccess
        "Unifying function and variable results in ceil predicate"
        (UnificationTerm (mkElemVar Mock.x))
        (UnificationTerm a5)
        [   ( [("x", a5)]
            , Predicate.makeCeilPredicate_ a5
            )
        ]
    , testGroup "inj unification tests" injUnificationTests
    , testCase "Unmatching constants is bottom" $
        andSimplifySuccess
            (UnificationTerm a)
            (UnificationTerm a1)
            []
    , testCase "Unmatching domain values is bottom" $
        andSimplifySuccess
            (UnificationTerm dv1)
            (UnificationTerm dv2)
            []
    , andSimplifyException "Unmatching constructor constant + domain value"
        (UnificationTerm a)
        (UnificationTerm dv2)
        "Cannot handle Constructor and DomainValue:\n\
        \/* Fl Fn D Sfa Cl */ a{}()\n\
        \/* Fl Fn D Sfa Cl */ \\dv{testSort{}}(/* Fl Fn D Sfa Cl */ \"dv2\")\n"
    , andSimplifyException "Unmatching domain value + constructor constant"
        (UnificationTerm dv1)
        (UnificationTerm a)
        "Cannot handle DomainValue and Constructor:\n\
        \/* Fl Fn D Sfa Cl */ \\dv{testSort{}}(/* Fl Fn D Sfa Cl */ \"dv1\")\n\
        \/* Fl Fn D Sfa Cl */ a{}()\n"
    , testCase "Unmatching domain value + nonconstructor constant" $
        andSimplifySuccess
            (UnificationTerm dv1)
            (UnificationTerm a2)
            [ UnificationResult
                { term = dv1
                , substitution = []
                , predicate = makeEqualsPredicate_ dv1 a2
                }
            ]
    , testCase "Unmatching nonconstructor constant + domain value" $
        andSimplifySuccess
            (UnificationTerm a2)
            (UnificationTerm dv1)
            [ UnificationResult
                { term = a2
                , substitution = []
                , predicate = makeEqualsPredicate_ a2 dv1
                }
            ]
    , testCase "non-functional pattern" $
        andSimplifyFailure
            (UnificationTerm (mkElemVar Mock.x))
            (UnificationTerm a3)
            (unsupportedPatterns
                "Unknown unification case."
                (mkElemVar Mock.x)
                a3
            )
    , testCase "SetVariable w. constructor" $
        andSimplifyFailure
            (UnificationTerm (f (Mock.mkTestSomeVariable "@x")))
            (UnificationTerm (f a))
            (unsupportedPatterns
                "Unknown unification case."
                (Mock.mkTestSomeVariable "@x")
                a
            )
    , testCase "SetVariable" $
        andSimplifyFailure
            (UnificationTerm (Mock.mkTestSomeVariable "@x"))
            (UnificationTerm a)
            (unsupportedPatterns
                "Unknown unification case."
                (Mock.mkTestSomeVariable "@x")
                a
            )
    , testCase "non-constructor symbolHead right" $
        andSimplifySuccess
            (UnificationTerm a)
            (UnificationTerm a2)
            [ UnificationResult
                { term = a
                , substitution = []
                , predicate = makeEqualsPredicate_ a a2
                }
            ]
    , testCase "non-constructor symbolHead left" $
        andSimplifySuccess
            (UnificationTerm a2)
            (UnificationTerm a)
            [ UnificationResult
                { term = a2
                , substitution = []
                , predicate = makeEqualsPredicate_ a2 a
                }
            ]
    , testCase "nested a=a1 is bottom" $
        andSimplifySuccess
            (UnificationTerm (f a))
            (UnificationTerm (f a1))
            []
          {- currently this cannot even be built because of builder checks
    , andSimplifyFailure "Unmatching sorts"
        (UnificationTerm aA)
        (UnificationTerm bA)
        UnificationError
        -}
    , testCase "Maps substitution variables"
        (assertEqual ""
            (Substitution.mkUnwrappedSubstitution
                [(inject . ElementVariableName <$> mkW "1", war' "2")]
            )
            (Substitution.unwrap
                . Substitution.mapVariables showUnifiedVar
                . Substitution.wrap
                . Substitution.mkUnwrappedSubstitution
                $ [(inject . ElementVariableName <$> mkV 1, var' 2)]
            )
        )
    , testCase "framed Map with concrete Map" $
            andSimplifySuccess
                (UnificationTerm
                    (Mock.concatMap
                        (Mock.builtinMap [(a, mkElemVar Mock.x)])
                        (mkElemVar Mock.m)
                    )
                )
                (UnificationTerm
                    (Mock.builtinMap [(a, constr a), (b, constr b)])
                )
                [ UnificationResult
                    { term =
                        Mock.builtinMap [(a, constr a) , (b, constr b)]
                    , predicate = Predicate.makeTruePredicate_
                    , substitution =
                        [ ("x", constr a)
                        , ("m", Mock.builtinMap [(Mock.b, constr b)])
                        ]
                    }
                ]
    , testCase "key outside of map" $
            andSimplifySuccess
                (UnificationTerm
                    (constr20
                        y
                        (Mock.concatMap
                            (Mock.builtinMap [(y, x)])
                            (mkElemVar Mock.m)
                        )
                    )
                )
                (UnificationTerm
                    (constr20
                        Mock.a
                        (Mock.builtinMap [(a, constr a), (b, constr b)])
                    )
                )
                [ UnificationResult
                    { term =
                        constr20
                            Mock.a
                            (Mock.builtinMap [(a, constr a), (b, constr b)])
                    , predicate = Predicate.makeTruePredicate Mock.testSort
                    , substitution =
                        [ ("x", constr a)
                        , ("y", a)
                        , ("m", Mock.builtinMap [(Mock.b, constr b)])
                        ]
                    }
                ]
    , testCase "key outside of map, symbolic opaque terms" $
            andSimplifySuccess
                (UnificationTerm
                    (constr20
                        y
                        (Mock.concatMap
                            (Mock.builtinMap [(y, x)])
                            (mkElemVar Mock.m)
                        )
                    )
                )
                (UnificationTerm
                    (constr20
                        Mock.a
                        (Mock.concatMap
                            (Mock.builtinMap [(a, constr a)])
                            (mkElemVar Mock.xMap)
                        )
                    )
                )
                [ UnificationResult
                    { term =
                        constr20
                            Mock.a
                            (Mock.concatMap
                                (Mock.builtinMap [(y, x)])
                                (mkElemVar Mock.m)
                            )
                    , predicate = Predicate.makeTruePredicate Mock.testSort
                    , substitution =
                        [ ("x", constr a)
                        , ("y", a)
                        , ("m", mkElemVar Mock.xMap)
                        ]
                    }
                ]
    ]
  where
    constr = Mock.functionalConstr10
    constr20 = Mock.constrFunct20TestMap
    x = mkElemVar Mock.x
    y = mkElemVar Mock.y

test_evaluated :: [TestTree]
test_evaluated =
    [ testCase "variable and functional term" $ do
        let evaluated = mkEvaluated a2
        andSimplifySuccess
            (UnificationTerm (mkElemVar Mock.x))
            (UnificationTerm evaluated)
            [ UnificationResult
                { term = evaluated
                , substitution = [("x", evaluated)]
                , predicate = Predicate.makeTruePredicate Mock.testSort
                }
            ]
    , unificationProcedureSuccess
        "variable and non-functional term"
        (UnificationTerm (mkElemVar Mock.x))
        (UnificationTerm (mkEvaluated a5))
        [   ( [("x", mkEvaluated a5)]
            , Predicate.makeCeilPredicate_ (mkEvaluated a5)
            )
        ]
    ]

test_unsupportedConstructs :: TestTree
test_unsupportedConstructs =
    testCase "Unsupported constructs" $
        andSimplifyFailure
            (UnificationTerm (f a))
            (UnificationTerm (f (mkImplies a (mkNext a1))))
            (unsupportedPatterns
                "Unknown unification case."
                a
                (mkImplies a (mkNext a1))
            )

injUnificationTests :: [TestTree]
injUnificationTests =
    [ testCase "Injected Variable" $
        andSimplifySuccess
            (UnificationTerm
                (Mock.sortInjectionSubToTop (mkElemVar Mock.xSubSort))
            )
            (UnificationTerm (Mock.sortInjectionSubToTop Mock.aSubsort))
            [ UnificationResult
                { term = Mock.sortInjectionSubToTop Mock.aSubsort
                , substitution = [("xSubSort", Mock.aSubsort)]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "Variable" $
        andSimplifySuccess
            (UnificationTerm (mkElemVar Mock.xTopSort))
            (UnificationTerm (Mock.sortInjectionSubToTop Mock.aSubsort))
            [ UnificationResult
                { term = Mock.sortInjectionSubToTop Mock.aSubsort
                , substitution =
                    [("xTopSort", Mock.sortInjectionSubToTop Mock.aSubsort)]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "Injected Variable vs doubly injected term" $ do
        term2 <-
            simplifyPattern
            $ UnificationTerm
                (Mock.sortInjectionSubToTop
                    (Mock.sortInjectionSubSubToSub Mock.aSubSubsort)
                )
        andSimplifySuccess
            (UnificationTerm
                (Mock.sortInjectionSubSubToTop (mkElemVar Mock.xSubSubSort))
            )
            term2
            [ UnificationResult
                { term = Mock.sortInjectionSubSubToTop Mock.aSubSubsort
                , substitution = [("xSubSubSort", Mock.aSubSubsort)]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "doubly injected variable vs injected term" $ do
        term1 <- simplifyPattern $ UnificationTerm
            (Mock.sortInjectionSubToTop
                (Mock.sortInjectionSubSubToSub (mkElemVar Mock.xSubSubSort))
            )
        andSimplifySuccess
            term1
            (UnificationTerm (Mock.sortInjectionSubSubToTop Mock.aSubSubsort))
            [ UnificationResult
                { term = Mock.sortInjectionSubSubToTop Mock.aSubSubsort
                , substitution = [("xSubSubSort", Mock.aSubSubsort)]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "doubly injected variable vs doubly injected term" $ do
        term1 <- simplifyPattern $ UnificationTerm
            (Mock.sortInjectionSubToTop
                (Mock.sortInjectionSubSubToSub Mock.aSubSubsort)
            )
        term2 <- simplifyPattern $ UnificationTerm
            (Mock.sortInjectionOtherToTop
                (Mock.sortInjectionSubSubToOther (mkElemVar Mock.xSubSubSort))
            )
        andSimplifySuccess
            term1
            term2
            [ UnificationResult
                { term = Mock.sortInjectionSubSubToTop Mock.aSubSubsort
                , substitution = [("xSubSubSort", Mock.aSubSubsort)]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "constant vs injection is bottom" $
        andSimplifySuccess
            (UnificationTerm Mock.aTopSort)
            (UnificationTerm (Mock.sortInjectionSubSubToTop Mock.aSubSubsort))
            []
    , testCase "unmatching nested injections" $ do
        term1 <-
            simplifyPattern
            $ UnificationTerm
                (Mock.sortInjectionSubToTop
                    (Mock.sortInjectionSubSubToSub Mock.aSubSubsort)
                )
        term2 <-
            simplifyPattern
            $ UnificationTerm
                (Mock.sortInjectionOtherToTop
                    (Mock.sortInjectionSubOtherToOther Mock.aSubOthersort)
                )
        andSimplifySuccess
            term1
            term2
            []
    , testCase "matching injections" $
        andSimplifySuccess
            (UnificationTerm (Mock.sortInjectionSubSubToTop Mock.aSubSubsort))
            (UnificationTerm
                (Mock.sortInjectionSubToTop (mkElemVar Mock.xSubSort))
            )
            [ UnificationResult
                { term = Mock.sortInjectionSubSubToTop Mock.aSubSubsort
                , substitution =
                    [   ( "xSubSort"
                        , Mock.sortInjectionSubSubToSub Mock.aSubSubsort
                        )
                    ]
                , predicate = Predicate.makeTruePredicate Mock.topSort
                }
            ]
    , testCase "unmatching injections" $
        andSimplifySuccess
            (UnificationTerm (Mock.sortInjectionOtherToTop Mock.aOtherSort))
            (UnificationTerm
                (Mock.sortInjectionSubToTop (mkElemVar Mock.xSubSort))
            )
            []
    ]

simplifyPattern :: UnificationTerm -> IO UnificationTerm
simplifyPattern (UnificationTerm term) = do
    Conditional { term = term' } <- runNoSMT $ runSimplifier testEnv simplifier
    return $ UnificationTerm term'
  where
    simplifier = do
        simplifiedPatterns <-
            Pattern.simplify SideCondition.top expandedPattern
        case MultiOr.extractPatterns simplifiedPatterns of
            [] -> return Pattern.bottom
            (config : _) -> return config
    expandedPattern = Pattern.fromTermLike term

makeEqualsPredicate_ :: TestTerm -> TestTerm -> TestPredicate
makeEqualsPredicate_ = Predicate.makeEqualsPredicate_
