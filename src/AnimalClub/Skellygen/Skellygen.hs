{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

module AnimalClub.Skellygen.Skellygen
    ( SkellyNode(..)
    , generateMesh
    ) where

import Control.Lens
import Control.DeepSeq
import GHC.Generics (Generic)
import Linear.Metric
import qualified Linear.Quaternion as Q
import Linear.V3
import Linear.Vector

import AnimalClub.Skellygen.Hierarchical
import AnimalClub.Skellygen.Mesh
import qualified AnimalClub.Skellygen.Quaternion as QH
import qualified AnimalClub.Skellygen.TRS as TRS

import qualified Debug.Trace as Debug

data SkellyNode = SkellyNode
    {
    _debugName :: String
    , _isRoot :: Bool
    , _children :: [SkellyNode]
    , _trs :: TRS.TRS Float -- ^ in parent space
    , _attachRot :: TRS.Rotation Float -- ^ rotation to be applied to _trs in parent space
    , _attachDistance :: Float -- ^ distance to extend _trs in direction of this node from parent node
    , _thickness :: Float -- ^ base physical size of joint.
    } deriving (Show, Generic, NFData)

--dummyParent :: SkellyNode
--dummyParent = SkellyNode True [] TRS.identity QH.identity 0.0 1.0
makeLenses ''SkellyNode

data BoxSkinParameters = BoxSkinParameters
    { extension :: (Float, Float) --how much box sticks out of each end (parent, node)
    , boxSize :: (Float, Float) --size of box at each joint (parent, node)
    } deriving (Show)

defaultBoxParam :: BoxSkinParameters
defaultBoxParam = BoxSkinParameters (0.005, 0.005) (0.005, 0.005)

_normalize :: (RealFloat a) => V3 a -> V3 a
_normalize v = (1 / norm v) *^ v

-- TODO it's better to write this function where it takes a
-- thickness square at the origin facing neutral and apply
-- _trs skn to it
generateSingleMeshLocal ::
       TRS.TRS Float -- ^ input node transform
    -> Float -- ^ input thickness
    -> Float -- ^ node parent thickness
    -> Mesh -- ^ output mesh
generateSingleMeshLocal pos ct pt =
    if length' < 1e-6
        then Mesh ([], [])
        else Mesh (startPoints ++ endPoints, sides ++ caps)
  where
    start' = V3 0 0 0 :: V3 Float
    end' = TRS._trans pos
    length' = norm (end' - start')
    normalized = _normalize $ end' - start'
    start = start' --  - ex *^ normalized
    end = end' -- + ey *^ normalized
    -- TODO normalAxis should use the up direction of pos
    --normalAxis = Debug.trace (show $ QH.fromTo (V3 0 1 0) normalized) $ Q.rotate (QH.fromTo (V3 0 1 0) normalized)
    normalAxis = Q.rotate (QH.fromTo (V3 0 1 0) normalized)
    startPoints = map mapfn [i * pi / 2.0 | i <- [0 .. 3]]
      where
        mapfn a =
            start ^+^ normalAxis npt
          where
            npt = V3 (pt * cos a) 0 (pt * sin a)
    endPoints = map mapfn [i * pi / 2.0 | i <- [0 .. 3]]
      where
        mapfn a = end ^+^ normalAxis npt
          where
            npt = V3 (ct * cos a) 0 (ct * sin a)
    sides =
        [0, 4, 1, 1, 4, 5, 1, 5, 2, 2, 5, 6, 2, 6, 7, 3, 2, 7, 3, 7, 0, 0, 7, 4]
    caps = [0, 1, 2, 2, 3, 0, 4, 5, 6, 6, 7, 4]

_generateMesh ::
       TRS.TRS Float -- ^ parent ABS transform
    -> Float -- ^ parent thickness
    -> SkellyNode -- ^ node to generate
    -> Mesh -- ^ output mesh
_generateMesh p_trs p_thick skn = selfMesh `mappend` mconcat cmeshes
  where
    thick = _thickness skn
    reltrs = _trs skn
    --selfMesh = Debug.trace ("skn: " ++ (show (_debugName skn)) ++ " p: " ++ show (TRS._trans p_trs) ++ " c: " ++ show (TRS._trans reltrs)) $
    --selfMesh = Debug.trace ("sknabs: " ++ show abstrs ++ " p: " ++ show (TRS._rot p_trs) ++ " c: " ++ show (TRS._rot reltrs)) $
    selfMesh =
        if _isRoot skn then emptyMesh else transformMesh p_trs $ generateSingleMeshLocal reltrs thick p_thick
    abstrs = p_trs >*> reltrs
    cmeshes = map (_generateMesh abstrs thick) (_children skn)

generateMesh ::
       SkellyNode -- ^ input top level parent node
    -> Mesh -- ^ output mesh
generateMesh skn = _generateMesh TRS.identity 1.0 skn