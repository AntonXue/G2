{-# LANGUAGE FlexibleContexts #-}

module Main where

import Test.Tasty
import Test.Tasty.HUnit

import GHC

import G2.Internals.Interface
import G2.Internals.Core as G2
import G2.Internals.Translation
import G2.Internals.Preprocessing
import G2.Internals.Symbolic
import G2.Internals.SMT


import Data.List
import qualified Data.Map  as M
import Data.Maybe
import qualified Data.Monoid as Mon

import UnitTests

import PeanoTest
import HigherOrderMathTest


-- | Requirements
-- We use these to define checks on tests returning function inputs
--     RForall f -- All the returned inputs satisfy the function f
--     RExists f -- At least one of the returned inputs satisfies the function f
--     AtLeast x -- At least x inputs are returned
--     AtMost  x -- At most x inputs are returned
--     Exactly x -- Exactly x inputs are returned
data Reqs = RForAll ([Expr] -> Bool) 
          | RExists ([Expr] -> Bool)
          | AtLeast Int
          | AtMost Int
          | Exactly Int

main :: IO ()
main = do
    defaultMain =<< tests

tests = return . testGroup "Tests"
    =<< sequence [
          sampleTests
        , unitTests
        ]

sampleTests =
    return . testGroup "Samples"
        =<< sequence [
                  checkExpr "tests/samples/" "tests/samples/AssumeAssert.hs" Nothing (Just "assertGt5") "outShouldBeGt5" 1 [Exactly 0]
                , checkExpr "tests/samples/" "tests/samples/AssumeAssert.hs" Nothing (Just "assertGt5") "outShouldBeGe5" 1 [AtLeast 1]
                , checkExpr "tests/samples/" "tests/samples/AssumeAssert.hs" (Just "assumeGt5") (Just "assertGt5") "outShouldBeGt5" 1 [Exactly 0]
                , checkExpr "tests/samples/" "tests/samples/AssumeAssert.hs" (Just "assumeGt5") (Just "assertGt5") "outShouldBeGe5" 1 [Exactly 0]
                , checkExprWithOutput "tests/samples/" "tests/samples/IfTest.hs" Nothing Nothing "f" 3 [RForAll (\[Const (CInt x), Const (CInt y), (Const (CInt r))] -> if x == y then r == x + y else r == y), AtLeast 2]

                -- , checkExpr "tests/samples/" "tests/samples/Peano.hs" (Just "fstIsEvenAddToFour") (Just "fstIsTwo") "add" 2 [RExists peano_0_4, RExists peano_4_0, Exactly 2]
                -- , checkExpr "tests/samples/" "tests/samples/Peano.hs" (Just "multiplyToFour") (Just "equalsFour") "add" 2 [RExists peano_1_4, RExists peano_4_1, Exactly 2]
                , checkExpr "tests/samples/" "tests/samples/Peano.hs" (Just "equalsFour") Nothing "add" 2 [RExists peano_0_4, RExists peano_1_3, RExists peano_2_2, RExists peano_3_1, RExists peano_4_0, Exactly 5]
                , checkExpr "tests/samples/" "tests/samples/Peano.hs" (Just "eqEachOtherAndAddTo4") Nothing "add" 2 [RForAll peano_2_2, Exactly 1]
                , checkExpr "tests/samples/" "tests/samples/Peano.hs" (Just "equalsFour") Nothing "multiply" 2 [RExists peano_1_4, RExists peano_2_2, RExists peano_4_1, Exactly 3]

                , checkExpr "tests/samples/" "tests/samples/HigherOrderMath.hs" (Just "isTrue0") Nothing "notNegativeAt0NegativeAt1" 1 [RExists negativeSquareRes, AtLeast 1]
                , checkExpr "tests/samples/" "tests/samples/HigherOrderMath.hs" (Just "isTrue1") Nothing "fixed" 2 [RExists abs2NonNeg, RExists abs2Neg, RExists squareRes, RExists fourthPowerRes, AtLeast 4]
                , checkExpr "tests/samples/" "tests/samples/HigherOrderMath.hs" (Just "isTrue2") Nothing "sameDoubleArgLarger" 2 [RExists addRes, RExists subRes, RExists pythagoreanRes, AtLeast 2]
                , checkExprWithOutput "tests/samples/" "tests/samples/HigherOrderMath.hs" Nothing Nothing "functionSatisfies" 4 [RExists functionSatisfiesRes, AtLeast 1]

                , checkExpr "tests/samples/" "tests/samples/McCarthy91.hs" (Just "lessThan91") Nothing "mccarthy" 1 [RForAll (\[Const (CInt x)] -> x <= 100), AtLeast 1]
                , checkExpr "tests/samples/" "tests/samples/McCarthy91.hs" (Just "greaterThan10Less") Nothing "mccarthy" 1 [RForAll (\[Const (CInt x)] -> x > 100), AtLeast 1]
                , checkExpr "tests/samples/" "tests/samples/McCarthy91.hs" (Just "lessThanNot91") Nothing "mccarthy" 1 [Exactly 0]
                , checkExpr "tests/samples/" "tests/samples/McCarthy91.hs" (Just "greaterThanNot10Less") Nothing "mccarthy" 1 [Exactly 0]
        ]

checkExpr :: String -> String -> Maybe String -> Maybe String -> String -> Int -> [Reqs] -> IO TestTree
checkExpr proj src m_assume m_assert entry i reqList = do
    exprs <- return . map fst =<< testFile proj src m_assume m_assert entry

    let ch = checkExpr' exprs i reqList

    return . testCase src
        $ assertBool ("Assume/Assert for file " ++ src ++ 
                      " with functions [" ++ (fromMaybe "" m_assume) ++ "] " ++
                                      "[" ++ (fromMaybe "" m_assert) ++ "] " ++
                                              entry ++ " failed.\n" ++ show exprs) ch

checkExprWithOutput :: String -> String -> Maybe String -> Maybe String -> String -> Int -> [Reqs] -> IO TestTree
checkExprWithOutput proj src m_assume m_assert entry i reqList = do
    exprs <- return . map (\(a, b) -> a ++ [b]) =<<  testFile proj src m_assume m_assert entry

    let ch = checkExpr' (exprs) i reqList

    return . testCase src
        $ assertBool ("Assume/Assert for file " ++ src ++ 
                      " with functions [" ++ (fromMaybe "" m_assume) ++ "] " ++
                                      "[" ++ (fromMaybe "" m_assert) ++ "] " ++
                                              entry ++ " failed.\n" ++ show exprs) ch

-- | Checks conditions on given expressions
--   Helper for checkExprOutput checkExprReach
checkExpr' :: [[Expr]] -> Int -> [Reqs] -> Bool
checkExpr' exprs i reqList =
    let
        argChecksAll = and . map (\f -> all (givenLengthCheck i f) exprs) $ [f | RForAll f <- reqList]
        argChecksEx = and . map (\f -> any (givenLengthCheck i f) exprs) $ [f | RExists f <- reqList]
        checkAtLeast = and . map ((>=) (length exprs)) $ [x | AtLeast x <- reqList]
        checkAtMost = and . map ((<=) (length exprs)) $ [x | AtMost x <- reqList]
        checkExactly = and . map ((==) (length exprs)) $ [x | Exactly x <- reqList]

        checkArgCount = and . map ((==) i . length) $ exprs
    in
    argChecksAll && argChecksEx && checkAtLeast && checkAtMost && checkExactly && checkArgCount

testFile :: String -> String -> Maybe String -> Maybe String -> String -> IO ([([Expr], Expr)])
testFile proj src m_assume m_assert entry = do
    -- raw_core <- mkGHCCore src
    -- let (rtenv, reenv) = mkG2Core raw_core
    (rtenv, reenv) <- hskToG2 proj src
    let tenv' = M.union rtenv (M.fromList prelude_t_decls)
    let eenv' = reenv
    let init_state = initState tenv' eenv' m_assume m_assert entry

    hhp <- getZ3ProcessHandles

    run smt2 hhp init_state

givenLengthCheck :: Int -> ([Expr] -> Bool) -> [Expr] -> Bool
givenLengthCheck i f e = if length e == i then f e else False
