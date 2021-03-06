{-|
Module      : AnimalNode
Description : this module allows animals to be defined (more readily) in code
Copyright   : (c) Peter Lu, 2018
License     : GPL-3
Maintainer  : chippermonky@email.com
Stability   : experimental

-}

{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}
--{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE TemplateHaskell #-}

-- TOOD split into files
-- AnimalScriptTypes.hs
-- AnimalProprty.hs
-- AnimalNode.hs

module AnimalClub.Skellygen.AnimalNode (
  AbsOrRel(..),
  unAbsOrRel,

  BoneFlag(..),
  BoneId(..),

  BoneMatcher,
  idMatcher,
  nameMatcher,
  flagMatcher,
  nameFlagMatcher,

  FlagTrans,
  defTransFlag,

  BoneTrans(..),
  composeBoneTrans,
  applyBoneTrans,

  AnimalNode(..),
  makeBoneIdList,
  flipAnimalNode,
) where

import           Relude

import qualified Data.List                as L
import           Lens.Micro.Platform      (makeLenses, set)
import qualified Text.Show

import           AnimalClub.Skellygen.TRS

import           Linear.Matrix            (M44)
import           Linear.V3


-- | indicates whether to treat the contained object as relative or absolute to its parent
data AbsOrRel a = Abs a | Rel a deriving (Generic, NFData, Functor, Show)

unAbsOrRel :: AbsOrRel a -> a
unAbsOrRel (Abs a) = a
unAbsOrRel (Rel a) = a

-- | flag bones to distinguish them
-- some built-in flags are provided for common use cases
data BoneFlag =
 BF_Front | BF_Back | BF_Left | BF_Right | BF_Top | BF_Bottom
 | BF_CustomS Text | BF_CustomI Int
 deriving
  (Generic, NFData, Eq, Ord, Show)

-- | BoneId is an identifier for a given bone
-- the name is a basic non-unique identifier
-- BoneFlags help distinguish non-unique named bones
data BoneId = BoneId Text [BoneFlag] deriving (Generic, NFData, Eq, Ord, Show)

-- | a function for matching BoneNames
type BoneMatcher = BoneId -> Bool

-- TODO delete why would you use this when you could just use WithBoneId
-- | creates a matcher for a very specific bone
idMatcher :: BoneId -> BoneMatcher
idMatcher bid bid' = bid == bid'

-- | creates a matcher for all bones with given name
nameMatcher :: Text -> BoneMatcher
nameMatcher name (BoneId name' _) = name == name'

-- | creates a matcher for all bones that have the given flags (and possibly others)
flagMatcher :: [BoneFlag] -> BoneMatcher
flagMatcher bfs (BoneId _ bfs') = length (L.intersect bfs bfs') == length bfs

-- | creates a matcher for all bones that have given flags and name
nameFlagMatcher :: Text -> [BoneFlag] -> BoneMatcher
nameFlagMatcher name bfs bid = nameMatcher name bid && flagMatcher bfs bid

type FlagTrans = [BoneFlag] -> [BoneFlag]

-- | this flag transformer automatically translate built-in 'BoneFlag's in the sensible way
-- does not work with 'ArbTrans', don't do it!
defTransFlag :: BoneTrans a -> FlagTrans
defTransFlag _ []                 = []
defTransFlag Same x               = x
defTransFlag ReflZ (BF_Left:xs)   = BF_Right:defTransFlag ReflZ xs
defTransFlag ReflZ (BF_Right:xs)  = BF_Left:defTransFlag ReflZ xs
defTransFlag ReflZ (x:xs)         = x:defTransFlag ReflZ xs
defTransFlag ReflX (BF_Front:xs)  = BF_Back:defTransFlag ReflX xs
defTransFlag ReflX (BF_Back:xs)   = BF_Front:defTransFlag ReflX xs
defTransFlag ReflX (x:xs)         = x:defTransFlag ReflX xs
defTransFlag ReflY (BF_Top:xs)    = BF_Bottom:defTransFlag ReflZ xs
defTransFlag ReflY (BF_Bottom:xs) = BF_Top:defTransFlag ReflZ xs
defTransFlag ReflY (x:xs)         = x:defTransFlag ReflZ xs
defTransFlag (ArbTrans _) _       = error "don't do this"


-- | user friendly representation of a Bone transformation
-- applies a transformation relative to identity
-- the transformation effects all children
-- e.g. if you have two legs, you only need to add ReflX at the hips
-- BoneTrans is applied to _trs'/_pos of AnimalNode'/AnimalNode respectively
-- and by extension it also affects _orientation of AnimalProperty
data BoneTrans a = Same | ReflX | ReflY | ReflZ | ArbTrans (M44 a -> M44 a) deriving (Generic, NFData)

instance Show (BoneTrans a) where
  show Same         = "Same"
  show ReflX        = "ReflX"
  show ReflY        = "ReflY"
  show ReflZ        = "ReflZ"
  show (ArbTrans _) = "ArbTrans"

-- | combine two BoneTrans together
composeBoneTrans :: (AnimalFloat a) => BoneTrans a -> BoneTrans a -> BoneTrans a
composeBoneTrans Same x      = x
composeBoneTrans x Same      = x
composeBoneTrans ReflX ReflX = Same
composeBoneTrans ReflY ReflY = Same
composeBoneTrans ReflZ ReflZ = Same
composeBoneTrans x y         = ArbTrans $ applyBoneTrans x . applyBoneTrans y

-- TODO change this to BoneTrans a -> M44 a -> M44 a
-- | applies BoneTrans to an M44
applyBoneTrans :: (AnimalFloat a) => BoneTrans a -> M44 a -> M44 a
applyBoneTrans Same         = id
applyBoneTrans ReflX        = mul_Scale_M44 (V3 (-1) 1 1)
applyBoneTrans ReflY        = mul_Scale_M44 (V3 1 (-1) 1)
applyBoneTrans ReflZ        = mul_Scale_M44 (V3 1 1 (-1))
applyBoneTrans (ArbTrans f) = f


-- TODO add optional orientation parameter
-- direction is always looking down bone, orientation determines rotation along that bone
-- except in null bone cases, in which case, I guess you need a second direction parameter :\
-- make it optional so it should look like
--data NodeOrientation = Default | Up (V3 Float) | Full (Quaternion Float)

-- TODO consider getting rid of AbsOrRel, too complicated..
-- | these define static properties that make up the base SkellyNode
-- user friendly version that is limited in what can be expressed
--
-- each Node is a "limb" between the node's position and its parent
-- if it is the top level node, it's parent assumes origin position
-- if it is a phantom node, it won't have an associated mesh but otherwise is the same
-- note that any top level node is effectively a phantom node
--
-- orientations are automatically determined based on parent position (see comments in AnimalScript)
-- positions and thickness can be specified as absolute or relative for convenience I guess
-- (albeit this makes things more complicated so consider switching to everything in Abs coordinates
--
-- finally, the contained 'BoneTrans' applies a transformation after all other transformations are done
-- this allows us to create animals with symmetrical parts and only defining the transformation on one part
--
data AnimalNode a = AnimalNode {
  _name      :: BoneId, -- ^ name and transformation if relevant
  _boneTrans :: BoneTrans a,
  _pos       :: AbsOrRel (V3 a), -- ^ position, relative to parent if rel, 'BoneTrans' in 'BoneName' is applied to this
  _thickness :: AbsOrRel a, -- ^ base thickness, relative to parent thickness if rel
  _isPhantom :: Bool, -- ^ if this is true, this node will be invisible (won't create a mesh)
  _children  :: [AnimalNode a]
  -- _nodeOrientation :: NodeOrientation
} deriving (Generic, NFData, Show)

makeLenses ''AnimalNode

foldAnimalNode :: (a -> AnimalNode b -> a) -> a -> AnimalNode b -> a
foldAnimalNode f acc an = L.foldl (foldAnimalNode f) (f acc an) (_children an)

-- | extracts all BoneIds from AnimalNode tree
makeBoneIdList :: AnimalNode a -> [BoneId]
makeBoneIdList = foldAnimalNode (\bids an ->  _name an:bids) []

-- | flip an AnimalNode, the children of the flipped parent will inherit the flipped parent's new transform
-- but their relative transforms do not change
--
-- N.B., there is currently no way to flip something that has child that has been flipped
-- without munging all the indices rendering the flipped children indistinguishable
-- if we are going to support nested flips, maybe try something this
-- flipAnimalNodeFancy :: BoneTrans -> [Int] -> AnimalNode -> AnimalNode
--
flipAnimalNode ::
 (AnimalFloat a)
 => BoneTrans a -- ^ the BoneTrans we want to apply
 -> FlagTrans -- ^ how to modify the flags of the Bone (and all its children)
 -> AnimalNode a -- ^ the node we want to apply the BoneTrans to
 -> AnimalNode a -- ^ the node with BoneTrans applied to it
flipAnimalNode bt ft an = set children newChildren $ set boneTrans newBoneTrans an where
 newBoneTrans = composeBoneTrans bt (_boneTrans an)
 newChildren = map (flipAnimalNode Same ft) (_children an)
