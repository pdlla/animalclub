{-|
Module      : Genotype
Description : Monad for building genes
Copyright   : (c) Peter Lu, 2018
License     : GPL-3
Maintainer  : chippermonky@email.com
Stability   : experimental

Monad for building genes using Gene.
This is the old version using MTL
-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module AnimalClub.Genetics.Internal.Unused.Genotype (
  -- * Monads
  -- $monaddoclink
  GenotypeT,
  Genotype,
  -- ** Monad evalution functions
  evalGeneBuilderT,
  evalGeneBuilder,
  -- * Gene building monad operations
  -- | push and pop operate on the Gene stack, while all other operations operate on the Gene defined by the stack
  gbPush,
  gbPop,
  gbSum,
  gbNormalizedSum,
  gbSumRange,
  gbNormalizedThresh,
  gbTypical,
  gbRandomRanges,
  gbByteSample
) where

import           Prelude

import           AnimalClub.Genetics.DNA
import           AnimalClub.Genetics.Gene

import           Control.Exception.Base    (assert)
import           Control.Monad             (forM)
import           Control.Monad.Identity    (Identity, runIdentity)
import           Control.Monad.Random      (RandT, evalRandT, getRandom)
import           Control.Monad.State.Lazy  (StateT, evalStateT, get, put, state)
import           Control.Monad.Writer.Lazy (WriterT, execWriterT)
import qualified Data.Vector.Generic       as G
import           System.Random             (RandomGen)

--import Debug.Trace

-- $monaddoclink
-- The 'FastGenebuilder' monad contains a state object holding the underlying DNA and a Gene stack representing the current scope of operations.
-- The monad also contains a Writer monad used to outputted computed values from the state object allowing the user to organize the output in any way they please.
-- All operations in this module treat the state DNA to be @read-only@ though there is no reason why it can't be modified

-- TODO write ParStateT Monad that takes advantage of applicative do to parallelize state transformations
-- i.e. tell/push/pop are the only things that change state, all operations in between
-- can be parallelized. c.f. haxl

-- | StateT monad state type
-- note (dna, []) is a valid State
-- and assumes the Gene covers all of dna
type GenotypeState = (DNA, [Gene])




-- artisinal free range monad this so that you can rpar it

-- allow output type to be parameterized please
-- | Monad transformer for building genes
type GenotypeT g w m = StateT GenotypeState (WriterT w (RandT g m))
-- | Monad for building genes
type Genotype g w = GenotypeT g w Identity

-- | evalute the builder and obtain its output
evalGeneBuilderT :: (RandomGen g, Monoid w, Monad m) => GenotypeT g w m a -> GenotypeState -> g -> m w
evalGeneBuilderT m s g = (flip evalRandT) g . execWriterT $ evalStateT m s

-- | evalute the builder and obtain its output
evalGeneBuilder :: (RandomGen g, Monoid w) => Genotype g w a -> GenotypeState -> g -> w
evalGeneBuilder m s g = runIdentity $ evalGeneBuilderT m s g

-- | internal helper function for folding Gene hierarchies in the builder
absoluteGene :: GenotypeState -> Gene
absoluteGene (dna, gtl) = foldr combineGene (Gene 0 (G.length dna)) gtl



-- | Push a genotype onto the hierarchy
gbPush :: (Monoid w, Monad m) => Gene -> GenotypeT g w m ()
gbPush gt = do
  (dna, gtl) <- get
  case gtl of
    (x:_) -> if geneLength gt > geneLength x
      then error ("prepending Gene with length greater than length of last Gene on stack " ++ show (geneLength gt) ++ " " ++ show (geneLength x))
      else return ()
    _ -> return ()
  put (dna, gt:gtl)
  return ()

-- | Pop a genotype from the hierarchy
gbPop :: (Monoid w, Monad m) => GenotypeT g w m ()
gbPop = do
  (dna, gtl) <- get
  case gtl of
    (_:xs) -> put (dna, xs)
    _      -> error "Popping an empty genotype stack."
  return ()


-- | Computation that adds all genes of current genotype
gbSum :: (Monoid w, Monad m) => GenotypeT g w m Int
gbSum = state gbSum' where
  gbSum' s = (geneSum (fst s) (absoluteGene s), s)


-- | Same as gbSum but normalized to [0,1]
gbNormalizedSum :: (Monoid w, Monad m) => GenotypeT g w m Float
gbNormalizedSum = state gbSum' where
  gbSum' (dna, gtl) = (answer, (dna, gtl)) where
    foldedGene = absoluteGene (dna, gtl)
    sum_ = geneSum dna foldedGene
    length_ = geneLength foldedGene
    answer = if length_ == 0 then 0 else 0.125 * fromIntegral sum_ / fromIntegral length_

-- | Computation returns True if gbNormalizedSum > thresh, False otherwise
gbSumRange :: (Monoid w, Monad m) => (Float,Float) -> GenotypeT g w m Float
gbSumRange (min',max') = do
  s <- gbNormalizedSum
  return $ min' + s * (max'-min')

-- | Computation returns True if gbNormalizedSum > thresh, False otherwise
gbNormalizedThresh :: (Monoid w, Monad m) => Float -> GenotypeT g w m Bool
gbNormalizedThresh thresh = do
  s <- gbNormalizedSum
  return $ s > thresh



-- | Computation that sums a gene in two parts, treating the first part as a multiplier of the second part
-- first 1/4 is multiplicative, last 3/4 is additive.
gbTypical :: (Monoid w, Monad m) => (Float, Float) -> GenotypeT g w m Float
gbTypical (min_, max_) = do
  (dna, gtl) <- get
  let
    l = _count (absoluteGene (dna, gtl))
    ml = l `quot` 4
  gbPush (Gene 0 ml)
  mult <- gbNormalizedSum
  gbPop
  gbPush (Gene ml (l-ml))
  add <- gbNormalizedSum
  gbPop
  return $ min_ + mult * add * (max_ - min_)


-- | Computation that randomly creates several genes fitting the input range
gbRandomRanges :: (RandomGen g, Monoid w, Monad m) => [(Float, Float)] -> GenotypeT g w m [Float]
gbRandomRanges ranges = do
  (dna, gtl) <- get
  let
    rl = length ranges
    gl = _count (absoluteGene (dna, gtl))
    l = gl `quot` rl
  return $ assert (l > 0) ()
  forM [0..(rl-1)] $ \i -> do
    let
      (min_, max_) = ranges !! i
      short = gbNormalizedSum >>= \x -> return $ min_ + (max_-min_) * x
      long = gbTypical (min_, max_)
    gbPush (Gene (i*l) l)
    rn <- getRandom
    output <- if (l < 20 || rn) then short else long
    gbPop
    return output

-- | returns an 8 length array that counts occurrence of each bit
gbByteSample :: (RandomGen g, Monoid w, Monad m) => GenotypeT g w m [Int]
gbByteSample = do
  (dna, gtl) <- get
  let
    foldedGene = absoluteGene (dna, gtl)
    bitCount = geneBitCount dna foldedGene
  return $ G.toList bitCount



--gbRandomContinuousSample :: (RandomGen g)







{-
-- TODO random stuff
GbRandomParams = GbRandomParams {
  maxDepth :: Int,
  maxNumChildren :: Int
  --random type weight parameter
}

--g is of class RandomGen
--type RandomGeneSubBuilder = State (g, )
--gbRandom :: (RandomGen g, Monoid w, Monad m) => Gene -> GbRandomParams -> GenotypeT m Float
-}
