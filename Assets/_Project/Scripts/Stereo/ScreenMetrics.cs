using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace Afterglow.Stereo
{
    // Physical screen size, which the lens distortion needs in meters.
    public static class ScreenMetrics
    {
        const float k_MetersPerInch = 0.0254f;
        const float k_MetersPerMillimeter = 0.001f;
        const float k_FallbackDpi = 160f;
        const int k_SourceLength = 128;

        // Width and height of the landscape screen in meters. `source` describes where the numbers
        // came from, for logging.
        //   Neither platform has an API for the screen's physical size, so each turns pixels into
        // meters its own way: Android reports a real per-axis density, while iOS needs a table
        // (Plugins/iOS/AfterglowScreenMetrics.mm). Unity's own Screen.dpi is the last resort on
        // both, because its table is keyed on the device model and so knows only the phones that
        // existed when that Unity version shipped: on a newer one it can report a wrong density, or
        // 0, and the stereo geometry is then wrong on every frame with nothing to say so.
        public static Vector2 GetScreenSizeMeters(out string source)
        {
#if UNITY_ANDROID && !UNITY_EDITOR
            if (TryGetAndroidMetrics(out var widthPixels, out var heightPixels, out var xdpi, out var ydpi))
            {
                source = $"Android {widthPixels}x{heightPixels} px at {xdpi:F1} x {ydpi:F1} dpi";
                return new Vector2(widthPixels / xdpi, heightPixels / ydpi) * k_MetersPerInch;
            }
#endif
#if UNITY_IOS && !UNITY_EDITOR
            if (TryGetIosMetrics(out var size, out source))
                return size;
#endif
            var dpi = Screen.dpi > 0f ? Screen.dpi : k_FallbackDpi;
            source = $"Screen {Screen.width}x{Screen.height} px at {dpi:F1} dpi" +
                     (Screen.dpi > 0f ? " (Unity's own table)" : $" ({k_FallbackDpi:F0} dpi fallback: Unity reported none)");
            return new Vector2(Screen.width, Screen.height) / dpi * k_MetersPerInch;
        }

#if UNITY_IOS && !UNITY_EDITOR
        // The native plugin's table, which is keyed on the screen's pixel size rather than the
        // device model, so a phone newer than this build still measures right.
        static bool TryGetIosMetrics(out Vector2 size, out string source)
        {
            size = default;
            source = null;
            var text = new StringBuilder(k_SourceLength);
            var result = Afterglow_ScreenSizeMillimeters(out var width, out var height, text, text.Capacity);
            if (result == 0 || width <= 0f || height <= 0f)
            {
                Debug.LogWarning("[Stereo] iOS couldn't measure the screen; falling back on Unity's own density.");
                return false;
            }

            source = text.ToString();
            // A guessed density is close but not exact, and the lens distortion is built on it.
            if (result == 2)
                Debug.LogWarning($"[Stereo] This phone's screen isn't in the table, so its density is a guess: {source}");
            size = new Vector2(width, height) * k_MetersPerMillimeter;
            return true;
        }

        [DllImport("__Internal")]
        static extern int Afterglow_ScreenSizeMillimeters(out float width, out float height, StringBuilder source, int sourceLength);
#endif

#if UNITY_ANDROID && !UNITY_EDITOR
        // Real pixel counts and per-axis densities, like the Cardboard SDK's screen_params.cc.
        static bool TryGetAndroidMetrics(out int width, out int height, out float xdpi, out float ydpi)
        {
            width = height = 0;
            xdpi = ydpi = 0f;
            try
            {
                using var unityPlayer = new AndroidJavaClass("com.unity3d.player.UnityPlayer");
                using var activity = unityPlayer.GetStatic<AndroidJavaObject>("currentActivity");
                using var windowManager = activity.Call<AndroidJavaObject>("getWindowManager");
                using var display = windowManager.Call<AndroidJavaObject>("getDefaultDisplay");
                using var metrics = new AndroidJavaObject("android.util.DisplayMetrics");
                display.Call("getRealMetrics", metrics);
                width = metrics.Get<int>("widthPixels");
                height = metrics.Get<int>("heightPixels");
                xdpi = metrics.Get<float>("xdpi");
                ydpi = metrics.Get<float>("ydpi");
            }
            catch (AndroidJavaException e)
            {
                Debug.LogWarning($"[Stereo] Couldn't read display metrics: {e.Message}");
                return false;
            }

            // The viewer holds the phone in landscape, so the long side is the width.
            if (height > width)
            {
                (width, height) = (height, width);
                (xdpi, ydpi) = (ydpi, xdpi);
            }
            return width > 0 && height > 0 && xdpi > 0f && ydpi > 0f;
        }
#endif
    }
}
