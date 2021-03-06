{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}


module AnimalClub.Skellygen.AnimalProperty (
  BoneMethod(..),
  defThickness, defLength, defOrientation, defColor,

  SkellyFunc(..),
  PrioritizedSkellyFunc(..),

  addValuesToBoneMethod, addValuesToSkellyFunc,

  AnimalProperty(..),
  orientation, distance, skinParams,
  AnimalPropertyMap,
  makeStartingAnimalPropertyMap,

  getAnimalProperty,
  generateAnimalProperties_
) where

import           Relude                          hiding (identity)
import           Relude.Unsafe                   ((!!))

import           Control.DeepSeq
import           Control.Exception
import qualified Data.List                       as L
import qualified Data.Map                        as M
import           Data.Maybe
import           GHC.Generics
import           Lens.Micro.Platform
import qualified Text.Show

import           AnimalClub.Skellygen.AnimalNode
import           AnimalClub.Skellygen.Linear     hiding (distance)
import           AnimalClub.Skellygen.TRS


import qualified Debug.Trace                     as Debug
--import Prelude hiding (read)
--import qualified Prelude (read)
--read x = Prelude.read $ Debug.trace x x


-- | the method type for transformation (with no values)
--data BoneMethodType = Thickness_ | Length_ | Orientation_ | Color_ deriving (Eq, Read, Show)

-- TODO rename ctors
-- TODO finish 'Color'
-- |
-- There are no defined overwrite rules when using TLOCombined
-- so do not use it together with Thickness Length and Orientation
-- or you will not be guaranteed which one overwrites which
-- FUTURE for performance, you could add `TLOCombined (Float, Float, Rotation)`
data BoneMethod a = Thickness a  |  Length a | Orientation (Rotation a) | Color () deriving (Read, Show, Generic, NFData)


-- | default (identity) bone methods
defThickness :: (AnimalFloat a) => BoneMethod a
defThickness = Thickness 1

defLength :: (AnimalFloat a) => BoneMethod a
defLength = Length 1

defOrientation :: (AnimalFloat a) => BoneMethod a
defOrientation = Orientation identityRotation

defColor :: BoneMethod a
defColor = Color ()

-- | internal version carries actual values of method
data SkellyFunc a where
 WithBoneId :: BoneId -> BoneMethod a -> SkellyFunc a
 WithBoneMatcher :: BoneMatcher -> BoneMethod a -> SkellyFunc a

instance (Show a) => Show (SkellyFunc a) where
 show (WithBoneId bid m)        = "with BoneId " ++ show bid ++ " " ++ show m
 show (WithBoneMatcher match m) = "with matcher " ++ show m

-- | bone matchers are applied in ascending order of its priority
newtype PrioritizedSkellyFunc a = PrioritizedSkellyFunc{ unPrioritizedSkellyFunc :: (Int, SkellyFunc a) }
--instance Ord PrioritizedSkellyFunc where
--  (<=) (PrioritizedSkellyFunc (a,_)) (PrioritizedSkellyFunc (b,_)) = a <= b

-- | adds values to parameters in BoneMethod_
-- N.B this does no error checking on length of list being passed in
addValuesToBoneMethod :: (AnimalFloat a) => BoneMethod a -> [a] -> BoneMethod a
addValuesToBoneMethod m vals = case m of
 Orientation x ->
  Orientation $ x * fromEulerXYZ (V3 (vals !! 0) (vals !! 1) (vals !! 2))
 Length x ->
  Length $ x * (vals !! 0)
 Thickness x ->
  Thickness $ x * (vals !! 0)
 Color x -> Color x

-- | adds values to parameters in BoneMethod inside SkellyFunc
-- N.B this does no error checking on length of list being passed in
addValuesToSkellyFunc :: (AnimalFloat a) => SkellyFunc a -> [a] -> SkellyFunc a
addValuesToSkellyFunc (WithBoneId bid m) vals = WithBoneId bid (addValuesToBoneMethod m vals)
addValuesToSkellyFunc (WithBoneMatcher matcher m) vals = WithBoneMatcher matcher (addValuesToBoneMethod m vals)

-- | used for generating skelly over each bone of the base skelly
-- these are mapped to properties in SkellyNode
data AnimalProperty a = AnimalProperty {
  _orientation :: Rotation a, -- ^ combines multiplicatively
  _distance    :: a, -- ^ combines multiplicatively
  _skinParams  :: a -- ^ combines multiplicatively
  -- mesh + UV style
  -- UV map properties
  -- texture name, stretch shift,
} deriving (Show, Generic, NFData)

makeLenses ''AnimalProperty

-- TODO rename to identityTRSAnimalProperty
-- | the identityTRS AnimalProperty
defaultAnimalProperty :: (AnimalFloat a) => AnimalProperty a
defaultAnimalProperty = AnimalProperty {
  _orientation = identityRotation,
  _distance = 1,
  _skinParams = 1
}


-- |
type AnimalPropertyMap a = M.Map BoneId (AnimalProperty a)

-- | makes AnimalPropertyMap with all BoneIds as keys and gives them the identityTRS property
makeStartingAnimalPropertyMap :: (AnimalFloat a) => [BoneId] -> AnimalPropertyMap a
makeStartingAnimalPropertyMap = M.fromList . map (\bid -> (bid,defaultAnimalProperty))



-- |
generateAnimalPropertiesInternal_ ::
 (AnimalFloat a)
 => AnimalPropertyMap a -- ^ accumulating map of properties.
 -> [PrioritizedSkellyFunc a] -- ^ list of properties
 -> AnimalPropertyMap a -- ^ output map list of properties
generateAnimalPropertiesInternal_ props psfs = L.foldl addProp props sorted_psfs where
 -- sort psfs by priority
 sorted_psfs = L.sortOn (fst . unPrioritizedSkellyFunc) psfs

 -- add a property to the map
 addProp :: (AnimalFloat a) => AnimalPropertyMap a -> PrioritizedSkellyFunc a -> AnimalPropertyMap a
 addProp accProp (PrioritizedSkellyFunc (_,sf)) = r where
  (matched, method) = case sf of
   WithBoneId bid method -> (fromMaybe M.empty $ accProp M.!? bid >>= \a -> return (M.singleton bid a), method)
   WithBoneMatcher matcher method -> (M.filterWithKey (\k _ -> matcher k) accProp, method)

  -- apply the current SkellyFunc to all matched bones
  mapfn _ oldProp = case method of
   Orientation x ->
     over orientation (x*) oldProp
   Length x ->
     over distance (x*) oldProp
   Thickness x ->
     over skinParams (x*) oldProp
   -- TODO
   Color _ -> oldProp
  changedPropMap = M.mapWithKey mapfn matched

  -- union will replace oldProps with newProps
  r = M.union changedPropMap accProp



-- If we were really awesome, we could clean out all the BoneIds that are untouched (and thus have defaultAnimalProperty) for performance but whatever
generateAnimalProperties_ ::
  (AnimalFloat a)
  => [BoneId] -- ^ list of all bones (will be given default property in the map)
  -> [PrioritizedSkellyFunc a] -- ^ list of all SkellyFunc
  -> AnimalPropertyMap a -- ^ output accumulated map of properties. EnumBone' property will override AllBone' property
generateAnimalProperties_ bids = generateAnimalPropertiesInternal_ (makeStartingAnimalPropertyMap bids)

-- | property access helpers
getAnimalProperty :: (AnimalFloat a) => BoneId -> AnimalPropertyMap a -> AnimalProperty a
getAnimalProperty boneId props = M.findWithDefault defaultAnimalProperty boneId props
