module Test.Kore.Syntax.Id
    ( test_Id
    -- * Re-exports
    , testId
    , module Kore.Syntax.Id
    ) where

import Prelude.Kore

import Test.Tasty

import Kore.Syntax.Id

import Test.Kore
    ( testId
    )
import Test.Terse

test_Id :: [TestTree]
test_Id =
    [ equals (testId "x") (noLocationId "x") "Eq"
    , on equals hash (testId "x") (noLocationId "x") "Hashable"
    , equals
        (idLocation $ generatedId "generated")
        AstLocationGeneratedVariable
        "generatedId"
    ]
