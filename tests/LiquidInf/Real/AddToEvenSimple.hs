-- cmd_line = (--no-keep-quals)

module AddToEvenSimple () where

import Prelude hiding (zipWith)

{-@ LIQUID "--no-termination" @-}

{-@ type Even = {v:Int | v mod 2 = 0} @-}

{-@ f :: Even -> Even @-}
f :: Int -> Int
f x = x + g x

-- Without the below refinement type for g, this file can not be verified
g :: Int -> Int
g x = 4 * x
