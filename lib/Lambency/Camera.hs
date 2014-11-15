{-# LANGUAGE RecordWildCards #-}
module Lambency.Camera (
  mkOrthoCamera,
  mkPerspCamera,
  getViewProjMatrix,

  getCamXForm,
  setCamXForm,
  getCamDist,
  setCamDist,
  getCamPos,
  setCamPos,
  getCamDir,
  setCamDir,
  getCamUp,
  setCamUp,
  getCamNear,
  setCamNear,
  getCamFar,
  setCamFar,

  camLookAt,

  mkFixedCam,
  mkViewerCam,
  mkDebugCam,
  mk2DCam,
) where
--------------------------------------------------------------------------------
import qualified Control.Wire as W
import qualified Graphics.UI.GLFW as GLFW
import FRP.Netwire.Input
import GHC.Float
import Lambency.Types
import qualified Lambency.Transform as XForm
import qualified Linear.Quaternion as Quat
import Linear
--------------------------------------------------------------------------------

mkXForm :: Vec3f -> Vec3f -> Vec3f -> XForm.Transform
mkXForm pos dir up = let
  r = signorm $ dir `cross` up
  u' = signorm $ r `cross` dir
  in XForm.translate pos $ XForm.fromCoordinateBasis (r, u', negate dir)

mkOrthoCamera :: Vec3f -> Vec3f -> Vec3f  ->
                 Float -> Float -> Float -> Float -> Float -> Float ->
                 Camera
mkOrthoCamera pos dir up l r t b n f = Camera

  (mkXForm pos dir up)

  Ortho {
    left = l,
    right = r,
    top = t,
    bottom = b
  }

  CameraViewDistance {
    near = n,
    far = f
  }

mkPerspCamera :: Vec3f -> Vec3f -> Vec3f ->
                 Float -> Float -> Float -> Float -> Camera
mkPerspCamera pos dir up fovy aspratio n f = Camera

  (mkXForm pos dir up)

  Persp {
    fovY = fovy,
    aspect = aspratio
  }

  CameraViewDistance {
    near = n,
    far = f
  }

-- !FIXME! Change the following functions to val -> Camera -> Camera
getCamXForm :: Camera -> XForm.Transform
getCamXForm (Camera xf _ _) = xf

setCamXForm :: Camera -> XForm.Transform -> Camera
setCamXForm (Camera _ cam dist) xf = Camera xf cam dist

getCamDist :: Camera -> CameraViewDistance
getCamDist (Camera _ _ dist) = dist

setCamDist :: Camera -> CameraViewDistance -> Camera
setCamDist (Camera loc cam _) dist = Camera loc cam dist

getCamPos :: Camera -> Vec3f
getCamPos = XForm.position . getCamXForm

setCamPos :: Camera -> Vec3f -> Camera
setCamPos c p = let
  xf = getCamXForm c
  nd = XForm.forward xf
  u = XForm.up xf
  in
   setCamXForm c $ mkXForm p (negate nd) u

getCamDir :: Camera -> Vec3f
getCamDir = negate . XForm.forward . getCamXForm

setCamDir :: Camera -> Vec3f -> Camera
setCamDir c d = let
  xf = getCamXForm c
  u = XForm.up xf
  p = XForm.position xf
  in
   setCamXForm c $ mkXForm p d u

getCamUp :: Camera -> Vec3f
getCamUp = XForm.up . getCamXForm

setCamUp :: Camera -> Vec3f -> Camera
setCamUp c u = let
  xf = getCamXForm c
  nd = XForm.forward xf
  p = XForm.position xf
  in
   setCamXForm c $ mkXForm p (negate nd) u

getCamNear :: Camera -> Float
getCamNear = near . getCamDist

setCamNear :: Camera -> Float -> Camera
setCamNear c n = let
  dist = getCamDist c
  in
   setCamDist c $ (\d -> d { near = n }) dist

getCamFar :: Camera -> Float
getCamFar = (far . getCamDist)

setCamFar :: Camera -> Float -> Camera
setCamFar c f = let
  dist = getCamDist c
  in
   setCamDist c $ (\d -> d { far = f }) dist

camLookAt :: Vec3f -> Camera -> Camera
camLookAt focus (Camera xf ty dist)
   | focus == pos = Camera xf ty dist
   | otherwise = Camera (mkXForm pos dir up) ty dist
  where
    pos = XForm.position xf
    dir = signorm $ focus - pos
    up = XForm.up xf

getViewMatrix :: Camera -> Mat4f
getViewMatrix (Camera xf _ _) =
  let
    extendWith :: Float -> Vec3f -> Vec4f
    extendWith w (V3 x y z) = V4 x y z w
    pos = negate . XForm.position $ xf
    (V3 sx sy sz) = XForm.scale xf
    r = XForm.right xf
    u = XForm.up xf
    f = XForm.forward xf
    te :: Vec3f -> Float -> Vec4f
    te n sc = extendWith (pos `dot` n) (sc *^ n)
  in adjoint $ V4 (te r sx) (te u sy) (te f sz) (V4 0 0 0 1)

mkProjMatrix :: CameraType -> CameraViewDistance -> Mat4f
mkProjMatrix (Ortho {..}) (CameraViewDistance{..}) =
  transpose $ ortho left right bottom top near far
mkProjMatrix (Persp {..}) (CameraViewDistance{..}) =
  transpose $ perspective fovY aspect near far

getProjMatrix :: Camera -> Mat4f
getProjMatrix (Camera _ ty dist) = mkProjMatrix ty dist

getViewProjMatrix :: Camera -> Mat4f
getViewProjMatrix c = (getViewMatrix c) !*! (getProjMatrix c)

--

mkFixedCam :: Monad m => Camera -> W.Wire s e m a Camera
mkFixedCam cam = W.mkConst $ Right cam

mkViewerCam :: Camera -> GameWire a Camera
mkViewerCam initialCam =
  let finalXForm :: ((Float, Float), Camera) -> Camera
      finalXForm ((0, 0), c) = c
      finalXForm ((mx, my), c@(Camera xform _ _)) =
        setCamPos (setCamDir c (signorm $ negate newPos)) newPos
        where
          newPos :: Vec3f
          newPos = XForm.transformPoint rotation $ getCamPos c

          rotation :: XForm.Transform
          rotation = flip XForm.rotate XForm.identity $
                     foldl1 (*) [
                       Quat.axisAngle (XForm.up xform) (-asin mx),
                       Quat.axisAngle (XForm.right xform) (-asin my)]

      handleScroll :: (Camera, (Double, Double)) -> Camera
      handleScroll (c, (_, sy)) =
        let camPos = getCamPos c
            camDir = getCamDir c
        in setCamPos c $ camPos ^+^ (double2Float sy *^ camDir)

      pressedMickies =
        (mousePressed GLFW.MouseButton'1 W.>>> mouseDelta) W.<|> (W.pure (0, 0))
  in
   W.loop $ W.second (
     W.delay initialCam W.>>>
     (pressedMickies W.&&& W.mkId) W.>>>
     (W.arr $ finalXForm) W.>>>
     ((W.mkId W.&&& mouseScroll) W.>>> W.arr handleScroll))
   W.>>> (W.arr $ \(_, cam) -> (cam, cam))

mkDebugCam :: Camera -> GameWire a Camera
mkDebugCam initCam = W.loop ((W.second (W.delay initCam W.>>> updCam)) W.>>> feedback)
  where
  feedback :: GameWire (a, b) (b, b)
  feedback = W.mkPure_ $ \(_, x) -> Right (x, x)

  tr :: GLFW.Key -> Float -> (XForm.Transform -> Vec3f) ->
        GameWire XForm.Transform XForm.Transform
  tr key sc dir = (trans W.>>> (keyPressed key)) W.<|> W.mkId
    where
      trans :: GameWire XForm.Transform XForm.Transform
      trans = W.mkSF $ \ts xf -> (XForm.translate (3.0 * (W.dtime ts) * sc *^ (dir xf)) xf, trans)

  updCam :: GameWire Camera Camera
  updCam = (W.mkId W.&&& (W.arr getCamXForm W.>>> xfWire)) W.>>> (W.mkSF_ $ uncurry stepCam)
    where

      xfWire :: GameWire XForm.Transform XForm.Transform
      xfWire =
        (tr GLFW.Key'W (-1.0) XForm.forward) W.>>>
        (tr GLFW.Key'S (1.0) XForm.forward) W.>>>
        (tr GLFW.Key'A (-1.0) XForm.right) W.>>>
        (tr GLFW.Key'D (1.0) XForm.right) W.>>>
        (W.mkId W.&&& mouseMickies) W.>>>
        (W.mkSF_ $ \(xf, (mx, my)) ->
          XForm.rotate
          (foldl1 (*) [
              Quat.axisAngle (XForm.up xf) (-asin mx),
              Quat.axisAngle (XForm.right xf) (-asin my)])
          xf)

      stepCam :: Camera -> XForm.Transform -> Camera
      stepCam cam newXForm = setCamXForm cam finalXForm
        where
          finalXForm = mkXForm
                       (XForm.position newXForm)
                       (negate $ XForm.forward newXForm)
                       (V3 0 1 0)

mk2DCam :: Int -> Int -> GameWire Vec2f Camera
mk2DCam sx sy = let
  toHalfF :: Integral a => a -> Float
  toHalfF x = 0.5 * (fromIntegral x)

  hx :: Float
  hx = toHalfF sx

  hy :: Float
  hy = toHalfF sy

  screenCenter :: V3 Float
  screenCenter = V3 hx hy 1

  trPos :: Vec2f -> Vec3f
  trPos (V2 x y) = (V3 x y 0) ^+^ screenCenter
 in
   W.mkSF_ $ \vec -> mkOrthoCamera
   (trPos vec) (negate XForm.localForward) XForm.localUp (-hx) (hx) (hy) (-hy) 0.01 50.0
