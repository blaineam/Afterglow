using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;
using UnityEngine.Rendering;

namespace CardboardXR.Stereo
{
    // The in-app browser for WebXR pages (Plugins/iOS/CardboardXRWebXR.mm).
    //
    // Safari has no WebXR on iOS, so a WebXR page opened anywhere on this phone falls back to a
    // flat view. This puts a web view over Unity's, injects an implementation of navigator.xr
    // (StreamingAssets/webxr/cardboardxr-webxr.js), and hands it this rig's own lens geometry, so
    // a page is drawn in stereo and corrected with exactly the numbers the native app uses.
    //
    // Unity keeps running underneath: it still owns the camera, the head tracking and the hand
    // tracking, and pushes its fused pose into the page every frame. What it stops doing is
    // drawing, since nothing it draws can be seen -- OnDemandRendering keeps Update at full rate
    // while rendering only occasionally, which matters on a phone whose thermal budget is already
    // the limit on this app.
    public static class WebBrowser
    {
        public enum Event
        {
            None = 0,
            SessionStart = 1,
            SessionEnd = 2,
            Close = 3,
        }

        // How rarely Unity draws while the browser is in front. It still updates every frame.
        const int k_HiddenRenderInterval = 12;
        const string k_ShimPath = "webxr/cardboardxr-webxr.js";

#if UNITY_IOS && !UNITY_EDITOR
        // What the frame interval was before the browser took the screen, to put back on close.
        static int s_RestoreRenderInterval = 1;
#endif

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        public static bool IsOpen
        {
            get
            {
#if UNITY_IOS && !UNITY_EDITOR
                return CardboardXR_WebIsOpen() != 0;
#else
                return false;
#endif
            }
        }

        // Opens a page over the app. The rig supplies the lens geometry, so it has to be built;
        // `hasPosition` says whether head tracking is giving position as well as rotation, which
        // the page is told so it doesn't imply the user can lean around things.
        public static bool Open(string url, StereoRig rig, bool hasPosition)
        {
            if (!Supported)
            {
                Debug.LogWarning("[WebXR] The browser is iOS only.");
                return false;
            }
            if (rig == null || rig.Lens == null)
            {
                Debug.LogWarning("[WebXR] No lens geometry yet, so a page would be drawn wrong.");
                return false;
            }

            var shim = ReadShim();
            if (shim == null)
                return false;

#if UNITY_IOS && !UNITY_EDITOR
            if (CardboardXR_WebOpen(url, BuildConfig(rig, hasPosition), shim) == 0)
            {
                Debug.LogWarning($"[WebXR] Couldn't open {url}");
                return false;
            }
            s_RestoreRenderInterval = OnDemandRendering.renderFrameInterval;
            OnDemandRendering.renderFrameInterval = k_HiddenRenderInterval;
            Debug.Log($"[WebXR] Opened {url}; Unity draws every {k_HiddenRenderInterval} frames while it's in front");
            return true;
#else
            return false;
#endif
        }

        public static void Close()
        {
#if UNITY_IOS && !UNITY_EDITOR
            if (CardboardXR_WebIsOpen() == 0)
                return;
            CardboardXR_WebClose();
            OnDemandRendering.renderFrameInterval = Mathf.Max(1, s_RestoreRenderInterval);
            Debug.Log("[WebXR] Closed; drawing every frame again");
#endif
        }

        // The head pose, in WebXR's coordinates. Unity is left-handed with +Z forward and WebXR is
        // right-handed with -Z forward, so Z flips -- on the position directly, and on the
        // rotation as the usual handedness swap (negating x and y leaves the same rotation).
        public static void PushPose(Vector3 position, Quaternion rotation)
        {
#if UNITY_IOS && !UNITY_EDITOR
            CardboardXR_WebPose(position.x, position.y, -position.z,
                                -rotation.x, -rotation.y, rotation.z, rotation.w);
#endif
        }

        // A pinch in front of the camera, or a tap, as a WebXR select.
        public static void Select()
        {
#if UNITY_IOS && !UNITY_EDITOR
            CardboardXR_WebSelect();
#endif
        }

        // Whatever the page last reported, cleared as it is read.
        public static Event TakeEvent()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return (Event)CardboardXR_WebTakeEvent();
#else
            return Event.None;
#endif
        }

        static string ReadShim()
        {
            var path = Path.Combine(Application.streamingAssetsPath, k_ShimPath);
            try
            {
                return File.ReadAllText(path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Debug.LogWarning($"[WebXR] Couldn't read {path}: {e.Message}");
                return null;
            }
        }

        // The viewer's optics, as the shim's config object. Hand-written rather than serialized:
        // it is a handful of numbers and JsonUtility cannot nest arrays of arrays.
        static string BuildConfig(StereoRig rig, bool hasPosition)
        {
            var lens = rig.Lens;
            var viewer = lens.Viewer;
            var invariant = CultureInfo.InvariantCulture;
            string F(float value) => value.ToString("G9", invariant);

            string Fov(Eye eye)
            {
                var fov = lens.GetFieldOfView(eye);
                return $"[{F(fov.x)},{F(fov.y)},{F(fov.z)},{F(fov.w)}]";
            }

            var k = new StringBuilder();
            foreach (var c in viewer.distortionCoefficients)
            {
                if (k.Length > 0) k.Append(',');
                k.Append(F(c));
            }

            return "{" +
                   $"\"screen\":[{F(lens.ScreenWidthMeters)},{F(lens.ScreenHeightMeters)}]," +
                   $"\"screenToLens\":{F(viewer.screenToLensDistance)}," +
                   $"\"interLens\":{F(viewer.interLensDistance)}," +
                   $"\"yEyeOffset\":{F(lens.YEyeOffsetMeters)}," +
                   $"\"k\":[{k}]," +
                   $"\"fov\":[{Fov(Eye.Left)},{Fov(Eye.Right)}]," +
                   $"\"hasPosition\":{(hasPosition ? "true" : "false")}," +
                   "\"eyeHeight\":1.6" +
                   "}";
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int CardboardXR_WebOpen(string url, string configJson, string shim);
        [DllImport("__Internal")] static extern void CardboardXR_WebClose();
        [DllImport("__Internal")] static extern int CardboardXR_WebIsOpen();
        [DllImport("__Internal")] static extern void CardboardXR_WebPose(float px, float py, float pz, float qx, float qy, float qz, float qw);
        [DllImport("__Internal")] static extern void CardboardXR_WebSelect();
        [DllImport("__Internal")] static extern int CardboardXR_WebTakeEvent();
#endif
    }
}
