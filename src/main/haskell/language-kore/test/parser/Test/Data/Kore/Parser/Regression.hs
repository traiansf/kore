module Test.Data.Kore.Parser.Regression
    ( InputFileName (..)
    , GoldenFileName (..)
    , regressionTest
    , regressionTests
    , regressionTestsInputFiles
    , test_regression
    , VerifyRequest(..)
    ) where

import           Test.Tasty                               (TestTree)
import           Test.Tasty.Golden                        (findByExtension,
                                                           goldenVsString)

import           Data.Kore.AST.PureToKore                 (definitionPureToKore)
import           Data.Kore.AST.Sentence
import           Data.Kore.ASTPrettyPrint
import           Data.Kore.ASTVerifier.DefinitionVerifier
import           Data.Kore.Error
import           Data.Kore.MetaML.Lift                    (liftDefinition)
import           Data.Kore.Parser.Parser

import           Control.Exception                        (bracket)
import           Control.Monad                            (void)
import qualified Data.ByteString.Lazy                     as LazyByteString
import qualified Data.ByteString.Lazy.Char8               as LazyChar8
import           System.Directory                         (getCurrentDirectory,
                                                           setCurrentDirectory)
import           System.FilePath                          (addExtension,
                                                           splitFileName, (</>))

import qualified Paths

newtype InputFileName = InputFileName FilePath
newtype GoldenFileName = GoldenFileName FilePath

data VerifyRequest
    = VerifyRequestWithLifting
    | VerifyRequestYes
    | VerifyRequestNo

regressionTests :: [InputFileName] -> [TestTree]
regressionTests = map regressionTestFromInputFile

regressionTestsInputFiles :: String -> IO [InputFileName]
regressionTestsInputFiles dir = do
    files <-
        withCurrentDirectory
            (Paths.dataFileName ".") (findByExtension [".kore"] dir)
    return (map InputFileName files)

regressionTestFromInputFile :: InputFileName -> TestTree
regressionTestFromInputFile inputFileName =
    regressionTest
        inputFileName
        (goldenFromInputFileName inputFileName)
        VerifyRequestWithLifting

regressionTest :: InputFileName -> GoldenFileName -> VerifyRequest -> TestTree
regressionTest
    (InputFileName inputFileName)
    (GoldenFileName goldenFileName)
    verifyRequest
  =
    goldenVsString
        ("Testing '" ++ inputFileName ++ "'")
        (Paths.dataFileName goldenFileName)
        (runParser inputFileName verifyRequest)

goldenFromInputFileName :: InputFileName -> GoldenFileName
goldenFromInputFileName (InputFileName inputFile) =
    GoldenFileName
        (directory </> "expected" </> addExtension inputFileName ".golden")
  where (directory, inputFileName) = splitFileName inputFile

toByteString :: Either String KoreDefinition -> LazyByteString.ByteString
toByteString (Left err) =
    LazyChar8.pack ("Parse error: " ++ err)
toByteString (Right definition) =
    LazyChar8.pack (prettyPrintToString definition)

verify :: KoreDefinition -> Either String KoreDefinition
verify definition =
    case verifyDefinition attributesVerification definition of
        Left e  -> Left (printError e)
        Right _ -> Right definition
  where
    attributesVerification :: AttributesVerification
    attributesVerification = case defaultAttributesVerification of
        Right verification -> verification
        Left err           -> error (printError err)

runParser :: String -> VerifyRequest -> IO LazyByteString.ByteString
runParser inputFileName verifyRequest = do
    fileContent <-
        withCurrentDirectory (Paths.dataFileName ".") (readFile inputFileName)
    let
        definition = do
            unverifiedDefinition <- fromKore inputFileName fileContent
            verifiedDefinition <- case verifyRequest of
                VerifyRequestWithLifting -> verify unverifiedDefinition
                VerifyRequestYes         -> verify unverifiedDefinition
                VerifyRequestNo          -> return unverifiedDefinition
            case verifyRequest of
                VerifyRequestWithLifting ->
                    void $ verify
                        (definitionPureToKore
                            (liftDefinition verifiedDefinition)
                        )
                VerifyRequestYes -> return ()
                VerifyRequestNo  -> return ()
            return verifiedDefinition
    return (toByteString definition)

withCurrentDirectory :: FilePath -> IO a -> IO a
withCurrentDirectory dir go =
    bracket pushd popd (const go)
  where
    pushd =
        do cur <- getCurrentDirectory
           setCurrentDirectory dir
           pure cur
    popd = setCurrentDirectory

test_regression :: IO [TestTree]
test_regression =
    regressionTests <$> regressionTestsInputFiles "../../../test/resources/"