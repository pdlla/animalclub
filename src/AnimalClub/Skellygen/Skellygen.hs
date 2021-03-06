{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}

module AnimalClub.Skellygen.Skellygen(
  SkellyNode(..)
  , generatePotatoMesh
  , generatePotatoMeshWithDebugging

  , generateLocalMesh
) where

import           Relude                       hiding (identity)
import           Relude.Unsafe                ((!!))

import           Control.Parallel.Strategies
import           GHC.Generics
import           Lens.Micro.Platform

import qualified Data.Vector.Generic          as G
import qualified Data.Vector.Storable.Mutable as MV

import           AnimalClub.Skellygen.Linear
import           AnimalClub.Skellygen.Mesh
import           AnimalClub.Skellygen.TRS




{-
  cube indexing for 'generateSingleLocalMesh' and 'generateSinglePotatoMesh'
  coordinates interpreted looking in direction of limb (from parent to child)


          start
          0-------1
        / |     / |
       3-------2  |
       |  4----|--5
       | /     | /
       7-------6
           end (

       x---/
          /|
         z |
           y



  (actually the current implementation is offset by 45 degrees)

  uv mapping of one face
  (0,0)   (1,0)
  0-------1
  |       |
  |       |
  3-------2
  (0,1)   (1,1)
-}


mconcat' :: (Monoid a) => [a] -> a
mconcat' = foldl' mappend mempty

-- |
-- prefixed names due to unfortunate naming conflict with AnimalNode
data SkellyNode a = SkellyNode
  {
  _snDebugName   :: String
  , _snIsPhantom :: Bool
  , _snChildren  :: [SkellyNode a]
  , _snM44Rel    :: M44 a -- ^ relative to parent
  , _snThickness :: a -- ^ base physical size of joint.
  , _snDebugMesh :: PotatoMesh a -- ^ for debugging and testing purposes only
  } deriving (Show, Generic, NFData)

--dummyParent :: SkellyNode
--dummyParent = SkellyNode True [] identityTRS identityRotation 0.0 1.0
makeLenses ''SkellyNode

data BoxSkinParameters a = BoxSkinParameters
  { extension :: (a, a) --how much box sticks out of each end (parent, node)
  , boxSize   :: (a, a) --size of box at each joint (parent, node)
  } deriving (Show)

defaultBoxParam :: (AnimalFloat a) => BoxSkinParameters a
defaultBoxParam = BoxSkinParameters (0.005, 0.005) (0.005, 0.005)

_normalize :: (AnimalFloat a) => V3 a -> V3 a
_normalize v = (1 / norm v) *^ v

-- same as above but formats different and adds normals + uvs
generateSinglePotatoMesh ::
  (AnimalFloat a)
  => M44 a -- ^ input node transform
  -> a -- ^ input thickness
  -> a -- ^ node parent thickness
  -> PotatoMesh a -- ^ output mesh
generateSinglePotatoMesh pos ct pt =
 if length' < 1e-6
  then emptyPotatoMesh
  else r
 where
  end' = view translation pos
  start' = V3 0 0 0
  length' = norm (end' - start')
  normalized = signorm $ end' - start'
  start = start' --  - ex *^ normalized
  end = end' -- + ey *^ normalized

  -- TODO rename this variable?? Why did I call it "upAxis"???
  -- TODO upAxis should use the up direction of pos
  -- right now all meshes are oriented the same way (edge of mesh pointing directly up)
  -- i.e. there is no rotation component along normalized for the mesh being generated
  upAxis = rotate (fromTo (V3 0 1 0) normalized)

  divs = 4 :: Int

  startPoints = map mapfn [(fromIntegral x) * pi / 2.0 | x <- [0..(divs-1)]] where
    mapfn a = start ^+^ upAxis npt where
      npt = V3 (pt * cos a) 0 (pt * sin a)

  endPoints = map mapfn [(fromIntegral x) * pi / 2.0 | x <- [0..(divs-1)]] where
    mapfn a = end ^+^ upAxis npt where
      npt = V3 (ct * cos a) 0 (ct * sin a)

  allPoints = startPoints ++ endPoints

  sides = [(0, 4, 1), (5, 1, 4), (1, 5, 2), (6, 2, 5), (2, 6, 3), (7, 3, 6), (3, 7, 0), (4, 0, 7)]
  caps = [(0, 1, 3), (2, 3, 1), (6, 5, 7), (4, 7, 5)]
  allIndices = sides ++ caps

  -- per face normals
  sideNormals = map mapfn [(fromIntegral x) * pi / 2.0 | x <- [0..(divs-1)]] where
    mapfn a = upAxis npt where
      -- rotate a little more to get normal for face
      a' = a + pi / fromIntegral divs
      npt = V3 (cos a') 0 (sin a')
  capNormals = map upAxis [V3 0 1 0, V3 0 (-1) 0]
  allNormals = (sideNormals ++ capNormals)

  -- rendy requires same buffer indices for position, normal and tex coords
  -- therefore we reindex everything and duplicate positions/normals
  p = map (\(a,b,c) -> [(allPoints !! a), (allPoints !! b), (allPoints !! c)]) allIndices
  -- repeat each normal 6x for each point on the 2 tris of each face
  n = map (\x -> [x,x,x,x,x,x]) allNormals
  tc = take 6 . repeat $ [V2 0 0 , V2 1 0, V2 0 1, V2 1 1, V2 0 1, V2 1 0]
  i = [(x+0, x+1, x+2)| y <- [0..11], let x = y*3]

  -- you can probably make this more efficient by directly building the vector rather than converting from a list
  r = PotatoMesh {
      positions = G.fromList $ mconcat' p
      , normals = G.fromList $ mconcat' n
      , texCoords = G.fromList $ mconcat' tc
      , indices = G.fromList $ i
    }

_generatePotatoMesh ::
  (AnimalFloat a)
  => M44 a -- ^ parent ABS transform
  -> a -- ^ parent thickness
  -> SkellyNode a -- ^ node to generate
  -> NonEmpty (PotatoMesh a) -- ^ output mesh
_generatePotatoMesh p_snM44 p_thick skn = selfLocalMesh :| (mconcat' cmeshes) where
  thick = _snThickness skn
  relm44 = _snM44Rel skn
  selfLocalMesh = if _snIsPhantom skn
    then emptyPotatoMesh
    else transformPotatoMeshM44 p_snM44 $ generateSinglePotatoMesh relm44 thick p_thick
  absM44 = p_snM44 !*! relm44
  cmeshes = parMap rdeepseq (toList . _generatePotatoMesh absM44 thick) (_snChildren skn)

-- | same as _generatePotatoMesh except populates snDebugMesh
_generatePotatoMeshWithDebugging ::
  (AnimalFloat a)
  => M44 a -- ^ parent ABS transform
  -> a -- ^ parent thickness
  -> SkellyNode a -- ^ node to generate
  -> (SkellyNode a, NonEmpty (PotatoMesh a)) -- ^ output mesh and SkellyNode with debug mesh populated
_generatePotatoMeshWithDebugging p_snM44 p_thick skn = (rSN, rMesh) where
  thick = _snThickness skn
  relm44 = _snM44Rel skn
  selfLocalMesh = if _snIsPhantom skn
    then emptyPotatoMesh
    else transformPotatoMeshM44 p_snM44 $ generateSinglePotatoMesh relm44 thick p_thick
  absM44 = p_snM44 !*! relm44
  (children, cmeshes) = unzip $ parMap rdeepseq (over _2 toList . _generatePotatoMeshWithDebugging absM44 thick) (_snChildren skn)
  rMesh = selfLocalMesh :| (mconcat cmeshes)
  rSN = skn { _snChildren = children, _snDebugMesh = selfLocalMesh }

generatePotatoMesh ::
  (AnimalFloat a)
  => SkellyNode a -- ^ input top level parent node
  -> PotatoMesh a -- ^ output mesh
generatePotatoMesh skn = concatPotatoMesh . toList $ _generatePotatoMesh identity 1.0 skn

-- | same as generatePotatoMesh except returns SkellyNode with populated _snDebugMesh
generatePotatoMeshWithDebugging ::
  (AnimalFloat a)
  => SkellyNode a -- ^ input top level parent node
  -> (SkellyNode a, PotatoMesh a) -- ^ output top level parent and mesh
generatePotatoMeshWithDebugging skn = (sn, concatPotatoMesh . toList $ pm)  where
  (sn, pm) = _generatePotatoMeshWithDebugging identity 1.0 skn






-- old local mesh stuff CAN DELETE
generateSingleLocalMesh ::
  (AnimalFloat a)
  => M44 a -- ^ input node transform
  -> a -- ^ input thickness
  -> a -- ^ node parent thickness
  -> LocalMesh a -- ^ output mesh
generateSingleLocalMesh pos ct pt =
 if length' < 1e-6
  then mempty
  else LocalMesh (startPoints ++ endPoints, sides ++ caps)
 where
  end' = view translation pos
  start' = V3 0 0 0
  length' = norm (end' - start')
  normalized = _normalize $ end' - start'
  start = start' --  - ex *^ normalized
  end = end' -- + ey *^ normalized

  -- TODO upAxis should use the up direction of pos
  upAxis = rotate (fromTo (V3 0 1 0) normalized)

  startPoints = map mapfn [i * pi / 2.0 | i <- [0,1,2,3]] where
   mapfn a = start ^+^ upAxis npt where
    npt = V3 (pt * cos a) 0 (pt * sin a)

  endPoints = map mapfn [i * pi / 2.0 | i <- [0,1,2,3]] where
   mapfn a = end ^+^ upAxis npt where
    npt = V3 (ct * cos a) 0 (ct * sin a)

  sides = [(0, 1, 4), (5, 4, 1), (1, 2, 5), (6, 5, 2), (2, 3, 6), (7, 6, 3), (3, 0, 7), (4, 7, 0)]
  caps = [(0, 1, 3), (2, 3, 1), (6, 7, 5), (4, 5, 7)]


_generateLocalMesh ::
  (AnimalFloat a)
  => M44 a -- ^ parent ABS transform
  -> a -- ^ parent thickness
  -> SkellyNode a -- ^ node to generate
  -> LocalMesh a -- ^ output mesh
_generateLocalMesh p_snM44 p_thick skn = selfLocalMesh <> mconcat cmeshes where
 thick = _snThickness skn
 relm44 = _snM44Rel skn
 --selfLocalMesh = Debug.trace ("skn: " ++ (show (_snDebugName skn)) ++ " p: " ++ show (_trans p_snTrs) ++ " c: " ++ show (_trans reltrs)) $
 --selfLocalMesh = Debug.trace ("sknabs: " ++ show abstrs ++ " p: " ++ show (_rot p_snTrs) ++ " c: " ++ show (_rot reltrs)) $
 selfLocalMesh = if _snIsPhantom skn
  then mempty
  else transformLocalMeshM44 p_snM44 $ generateSingleLocalMesh relm44 thick p_thick
 absM44 = p_snM44 !*! relm44
 cmeshes = map (_generateLocalMesh absM44 thick) (_snChildren skn)


generateLocalMesh ::
  (AnimalFloat a)
  => SkellyNode a -- ^ input top level parent node
  -> LocalMesh a -- ^ output mesh
generateLocalMesh skn = _generateLocalMesh identity 1.0 skn
