using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;
using UnityEngine.Rendering;

namespace Afterglow.Stereo
{
    // The in-app browser for WebXR pages (Plugins/iOS/AfterglowWebXR.mm).
    //
    // Safari has no WebXR on iOS, so a WebXR page opened anywhere on this phone falls back to a
    // flat view. This puts a web view over Unity's, injects an implementation of navigator.xr
    // (StreamingAssets/webxr/afterglow-webxr.js), and hands it this rig's own lens geometry, so
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
            // The start page's "Clear history" link (afterglow://clear-history).
            ClearHistory = 4,
            // The start page is up and can take its bookmarks and history.
            StartPage = 5,
        }

        // How rarely Unity draws while the browser is in front. It still updates every frame.
        const int k_HiddenRenderInterval = 12;
        // The page's size in pixels, which is also the size it lays out for. Wide enough that a
        // site's desktop layout fits, small enough to snapshot a dozen times a second.
        public const int WindowWidth = 1024;
        public const int WindowHeight = 768;
        const string k_ShimPath = "webxr/afterglow-webxr.js";

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
                return Afterglow_WebIsOpen() != 0;
#else
                return false;
#endif
            }
        }

        // Opens a page over the app. The rig supplies the lens geometry, so it has to be built;
        // `hasPosition` says whether head tracking is giving position as well as rotation, which
        // the page is told so it doesn't imply the user can lean around things.
        // `windowed` hangs the page on a quad in the scene, which is what browsing wants; an
        // immersive session switches to the full screen later, because only that needs the frame
        // rate a snapshot cannot give.
        public static bool Open(string url, StereoRig rig, bool hasPosition, bool windowed = true)
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
            if (Afterglow_WebOpen(url, BuildConfig(rig, hasPosition), shim,
                                    windowed ? 1 : 0, WindowWidth, WindowHeight) == 0)
            {
                Debug.LogWarning($"[WebXR] Couldn't open {url}");
                return false;
            }
            // Only an overlay hides the scene; a window in it needs the scene drawn as usual.
            if (!windowed)
            {
                s_RestoreRenderInterval = OnDemandRendering.renderFrameInterval;
                OnDemandRendering.renderFrameInterval = k_HiddenRenderInterval;
            }
            Debug.Log($"[WebXR] Opened {url} {(windowed ? "as a window in the scene" : "over the scene")}");
            return true;
#else
            return false;
#endif
        }

        public static void Close()
        {
#if UNITY_IOS && !UNITY_EDITOR
            if (Afterglow_WebIsOpen() == 0)
                return;
            Afterglow_WebClose();
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
            Afterglow_WebPose(position.x, position.y, -position.z,
                                -rotation.x, -rotation.y, rotation.z, rotation.w);
#endif
        }

        // A pinch in front of the camera, or a tap, as a WebXR select.
        public static void Select()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebSelect();
#endif
        }

        // Whatever the page last reported, cleared as it is read.
        public static Event TakeEvent()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return (Event)Afterglow_WebTakeEvent();
#else
            return Event.None;
#endif
        }

        // The page's latest picture, uploaded into `target`, which is resized to fit the first
        // time. False when nothing has changed since the last call, so a still page costs nothing.
        public static bool TryUpdateTexture(ref Texture2D target)
        {
#if UNITY_IOS && !UNITY_EDITOR
            if (Afterglow_WebPixels(out var bytes, out var width, out var height) == 0)
                return false;
            if (bytes == IntPtr.Zero || width <= 0 || height <= 0)
                return false;
            if (target == null || target.width != width || target.height != height)
            {
                if (target != null)
                    UnityEngine.Object.Destroy(target);
                target = new Texture2D(width, height, TextureFormat.BGRA32, false, false)
                {
                    name = "Web Page",
                    wrapMode = TextureWrapMode.Clamp,
                };
            }
            target.LoadRawTextureData(bytes, width * height * 4);
            target.Apply(false, false);
            return true;
#else
            return false;
#endif
        }

        // A click where the gaze met the window: 0-1 across and down from the page's top left.
        public static void ClickAt(float u, float v)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebClickAt(u, v);
#endif
        }

        // Draws a crosshair at that point on the page and outlines whatever a click would land
        // on. The page carries them, so the snapshot shows them: aiming through a lens is
        // imprecise enough without having to guess the target.
        public static void HoverAt(float u, float v)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebHoverAt(u, v);
#endif
        }

        // Scrolls whatever is under that point, falling back to the window. Pages that keep
        // their content in an inner scroller ignore a window scroll entirely.
        public static void ScrollAt(float u, float v, float dx, float dy)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebScrollAt(u, v, dx, dy);
#endif
        }

        public static void GoBack()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebGoBack();
#endif
        }

        public static void GoForward()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebGoForward();
#endif
        }

        public static void Reload()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebReload();
#endif
        }

        // Types into whatever field the page has focused. Nothing focused and the page says so
        // rather than putting the text somewhere arbitrary; the caller should be sending it to
        // the address bar instead, which TextFocused is for.
        public static void Type(string text)
        {
            if (string.IsNullOrEmpty(text))
                return;
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebType(text);
#endif
        }

        // "Backspace", "Clear" or "Enter". Enter commits: it offers the page the key events
        // first and submits the form itself if nothing came of them.
        public static void Key(string key)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebKey(key);
#endif
        }

        // Whether the page has a text field focused, which decides where typing goes.
        public static bool TextFocused
        {
            get
            {
#if UNITY_IOS && !UNITY_EDITOR
                return Afterglow_WebTextFocused() != 0;
#else
                return false;
#endif
            }
        }

        const int k_HostLength = 256;
        const int k_CredentialLength = 1024;

        // A login the page just submitted, once, so the app can offer to keep it. The password
        // passes through here and nowhere else: never log it.
        public static bool TryTakeCredential(out string host, out string user, out string password)
        {
            host = user = password = null;
#if UNITY_IOS && !UNITY_EDITOR
            var hostBuffer = new StringBuilder(k_HostLength);
            var userBuffer = new StringBuilder(k_CredentialLength);
            var passBuffer = new StringBuilder(k_CredentialLength);
            if (Afterglow_WebTakeCredential(hostBuffer, hostBuffer.Capacity, userBuffer, userBuffer.Capacity, passBuffer, passBuffer.Capacity) == 0)
                return false;
            host = hostBuffer.ToString();
            user = userBuffer.ToString();
            password = passBuffer.ToString();
            return host.Length > 0;
#else
            return false;
#endif
        }

        // The host of a page that showed a login form, once, so the app can offer a saved login.
        public static bool TryTakeLoginHost(out string host)
        {
            host = null;
#if UNITY_IOS && !UNITY_EDITOR
            var buffer = new StringBuilder(k_HostLength);
            if (Afterglow_WebTakeLoginHost(buffer, buffer.Capacity) == 0)
                return false;
            host = buffer.ToString();
            return host.Length > 0;
#else
            return false;
#endif
        }

        // Puts a saved login into the page's form.
        public static void Fill(string user, string password)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebFill(user ?? "", password ?? "");
#endif
        }

        // Ends the page's immersive session, as the page's own Exit VR button would.
        public static void EndSession()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebEndSession();
#endif
        }

        // Runs a script in the page: how the app hands the start page its lists.
        public static void RunScript(string script)
        {
            if (string.IsNullOrEmpty(script))
                return;
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebRunScript(script);
#endif
        }

        public static void LoadUrl(string url)
        {
            if (string.IsNullOrEmpty(url))
                return;
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebLoadUrl(url);
#endif
        }

        // What the page is showing now, for the address bar.
        public static string CurrentUrl
        {
            get
            {
#if UNITY_IOS && !UNITY_EDITOR
                var needed = Afterglow_WebCopyUrl(null, 0);
                if (needed <= 0)
                    return string.Empty;
                var buffer = new byte[needed + 1];
                Afterglow_WebCopyUrl(buffer, buffer.Length);
                return Encoding.UTF8.GetString(buffer, 0, needed);
#else
                return string.Empty;
#endif
            }
        }

        // The page's title, for its tab.
        public static string CurrentTitle
        {
            get
            {
#if UNITY_IOS && !UNITY_EDITOR
                var needed = Afterglow_WebCopyTitle(null, 0);
                if (needed <= 0)
                    return string.Empty;
                var buffer = new byte[needed + 1];
                Afterglow_WebCopyTitle(buffer, buffer.Length);
                return Encoding.UTF8.GetString(buffer, 0, needed);
#else
                return string.Empty;
#endif
            }
        }

        // Where typed text should take you. A scheme is obeyed; something shaped like a host
        // gets https; anything else was meant as a search, which is the common case and the one
        // a browser gets wrong most visibly.
        //
        // DuckDuckGo because it does not need an account or carry one around, which is the same
        // reason the rest of this app keeps to itself.
        const string k_Search = "https://duckduckgo.com/?q=";

        public static string NormalizeAddress(string typed)
        {
            if (string.IsNullOrWhiteSpace(typed))
                return null;
            var text = typed.Trim();
            // Only a real scheme can carry its own slashes. Matching on a bare colon would read
            // "localhost:8080" as one.
            if (text.Contains("://"))
                return text;
            if (text.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
                return text;

            var host = text.Split('/')[0];
            // A space means it was a search however much the rest of it looks like a host, and a
            // trailing dot means the end of a sentence rather than a domain.
            var looksLikeHost = !text.Contains(' ')
                                && !host.EndsWith(".", StringComparison.Ordinal)
                                && (host.Contains('.')
                                    || host.StartsWith("localhost", StringComparison.OrdinalIgnoreCase));
            return looksLikeHost ? "https://" + text : k_Search + Uri.EscapeDataString(text);
        }

        // Moves the page between a quad in the scene and the whole screen.
        public static void SetWindowed(bool windowed)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_WebSetWindowed(windowed ? 1 : 0);
            if (windowed)
            {
                OnDemandRendering.renderFrameInterval = Mathf.Max(1, s_RestoreRenderInterval);
            }
            else
            {
                s_RestoreRenderInterval = OnDemandRendering.renderFrameInterval;
                OnDemandRendering.renderFrameInterval = k_HiddenRenderInterval;
            }
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
                   // Phone view: one picture filling the screen, no lens correction, for holding
                   // the phone in your hand rather than wearing it. The page has to be told,
                   // otherwise it keeps drawing a split, distorted pair nobody is looking through.
                   $"\"mono\":{(rig.IsMono ? "true" : "false")}," +
                   $"\"monoFov\":{F(rig.MonoFieldOfView * Mathf.Deg2Rad)}," +
                   "\"eyeHeight\":1.6" +
                   "}";
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_WebOpen(string url, string configJson, string shim, int windowed, int pixelWidth, int pixelHeight);
        [DllImport("__Internal")] static extern int Afterglow_WebPixels(out IntPtr bytes, out int width, out int height);
        [DllImport("__Internal")] static extern void Afterglow_WebClickAt(float u, float v);
        [DllImport("__Internal")] static extern void Afterglow_WebHoverAt(float u, float v);
        [DllImport("__Internal")] static extern void Afterglow_WebScrollAt(float u, float v, float dx, float dy);
        [DllImport("__Internal")] static extern void Afterglow_WebGoBack();
        [DllImport("__Internal")] static extern void Afterglow_WebGoForward();
        [DllImport("__Internal")] static extern void Afterglow_WebReload();
        [DllImport("__Internal")] static extern void Afterglow_WebType(string text);
        [DllImport("__Internal")] static extern void Afterglow_WebKey(string key);
        [DllImport("__Internal")] static extern int Afterglow_WebTextFocused();
        [DllImport("__Internal")] static extern void Afterglow_WebLoadUrl(string url);
        [DllImport("__Internal")] static extern void Afterglow_WebRunScript(string script);
        [DllImport("__Internal")] static extern void Afterglow_WebEndSession();
        [DllImport("__Internal")] static extern int Afterglow_WebTakeCredential(StringBuilder host, int hostLength, StringBuilder user, int userLength, StringBuilder pass, int passLength);
        [DllImport("__Internal")] static extern int Afterglow_WebTakeLoginHost(StringBuilder host, int hostLength);
        [DllImport("__Internal")] static extern void Afterglow_WebFill(string user, string pass);
        [DllImport("__Internal")] static extern int Afterglow_WebCopyUrl(byte[] buffer, int capacity);
        [DllImport("__Internal")] static extern int Afterglow_WebCopyTitle(byte[] buffer, int capacity);
        [DllImport("__Internal")] static extern void Afterglow_WebSetWindowed(int windowed);
        [DllImport("__Internal")] static extern void Afterglow_WebClose();
        [DllImport("__Internal")] static extern int Afterglow_WebIsOpen();
        [DllImport("__Internal")] static extern void Afterglow_WebPose(float px, float py, float pz, float qx, float qy, float qz, float qw);
        [DllImport("__Internal")] static extern void Afterglow_WebSelect();
        [DllImport("__Internal")] static extern int Afterglow_WebTakeEvent();
#endif
    }
}
