{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}

import AnimalClub.Genetics

import Test.QuickCheck
import qualified Data.Vector.Unboxed         as V
import           Data.Word
import           System.Random

import Debug.Trace


instance Arbitrary (DNA) where
    arbitrary = sized (\n -> V.generateM n (\_ -> arbitraryBoundedIntegral :: Gen Word8))

dummyGen = mkStdGen 0


extractFirstValue = head . snd . head

{- Breeding tests -}
prop_basicbreedingtest :: Bool
prop_basicbreedingtest =
    let
        n = 10
        firstDNA = V.replicate n (0x00::Word8) --all recessive
        secondDNA = V.replicate n (0xFF::Word8) --all dominant
        gen = mkStdGen 0
        bread = breed gen firstDNA secondDNA
        sm = extractFirstValue $ evalGeneBuilder (gbSum >>= tellGene "". fromIntegral) (bread, []) dummyGen
    in
        sm == fromIntegral n*4


{- GeneBuilder tests -}
prop_gbNormalizedSum_test :: DNA -> Bool
prop_gbNormalizedSum_test dna = (o >= 0.0) && (o <= 1.0) where
    o = extractFirstValue $ evalGeneBuilder (gbNormalizedSum >>= tellGene "") (dna, [])  dummyGen

prop_gbSum_test :: DNA -> Bool
prop_gbSum_test dna = (o >= 0.0) && (o <= l) where
    l = fromIntegral $ 8 * V.length dna
    o = extractFirstValue  $ evalGeneBuilder (gbSum >>= tellGene "" . fromIntegral) (dna, []) dummyGen

prop_gbTypical :: DNA -> (Float, Float) -> Bool
prop_gbTypical dna (a', b') = (o >= a) && (o <= b) where
    a = min a' b'
    b = max a' b'
    o = extractFirstValue  $ evalGeneBuilder (gbTypical (a, b) >>= tellGene "") (dna, []) dummyGen

prop_gbRandomRanges :: DNA -> [(Float, Float)] -> Bool
prop_gbRandomRanges dna' ranges' = pass where
    ranges = map (\(a,b)->(min a b, max a b)) ranges'
    rl = length ranges
    dna'' = V.cons 0x00 dna'
    --replicate our definitely non-empty dna a bunch of times until it's long enough
    makedna x = if 4 * V.length x < 8 * rl then makedna (x V.++ dna'') else x
    dna = makedna dna''
    o = mconcat . map snd $ evalGeneBuilder (gbRandomRanges ranges >>= mapM (tellGene "")) (dna, []) dummyGen
    pass = all (\((mn,mx),x) -> (x >= mn) && (x <= mx)) $ zip ranges o

--prop_convergence :: Int -> Bool
--prop_convergence seed = where
--    dna =



--Template haskell nonsense to run all properties prefixed with "prop_" in this file
return []
main = $quickCheckAll
--main = $verboseCheckAll
