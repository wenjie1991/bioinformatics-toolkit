module Tests.ChIPSeq (tests) where

import Bio.Data.Bed
import Bio.ChIPSeq
import Data.Conduit
import Test.Tasty
import Test.Tasty.HUnit
import qualified Data.Vector as V

peaks :: IO [BED3]
peaks = readBed' "tests/data/peaks.bed"

tags :: Source IO BED
tags = readBed "tests/data/example.bed"

tests :: TestTree
tests = testGroup "Test: Bio.ChIPSeq"
    [ testCase "rpkm" testRPKM
    ]

testRPKM :: Assertion
testRPKM = do regions <- peaks
              r1 <- tags $$ rpkm regions
              r2 <- rpkmFromBam regions "tests/data/example.bam"
              V.toList r1 @=? r2