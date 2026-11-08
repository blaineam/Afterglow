using System;
using UnityEngine;

namespace Afterglow.Stereo
{
    // How far the viewer's focus wheel has moved the lens carriage, in meters, added to the
    // viewer profile's screenToLensDistance.
    //
    // A Cardboard viewer profile describes a viewer whose lenses don't move, so screenToLensDistance
    // is one number and a QR code is the only way to change it. The printed viewers in this
    // project's hardware folder have a focus wheel that slides the lens carriage, which no profile
    // can express: turn the wheel and the real distance is no longer the one the distortion is built
    // from, so the image is sharp but the scale and the distortion correction are both slightly off.
    // The same happens when a phone's own thickness moves its screen, which is why the offset is
    // kept per viewer *and* per screen size.
    //
    // This is that missing number, set by hand from the settings panel, saved, and applied on top of
    // the profile. Zero means the carriage is where the profile says.
    public static class ViewerFocus
    {
        // Enough travel to cover the printed viewers' wheels, which move the carriage a few
        // millimeters either way, with room to spare and without allowing a nonsensical distance.
        public const float MinOffset = -0.012f;
        public const float MaxOffset = 0.012f;
        public const float Step = 0.0005f;

        const string k_Key = "Afterglow.FocusOffset";

        static bool s_Loaded;
        static float s_Offset;

        // Raised when the offset changes, so the rig can rebuild its lenses.
        public static event Action Changed;

        public static float Offset
        {
            get
            {
                if (!s_Loaded)
                {
                    s_Offset = Mathf.Clamp(PlayerPrefs.GetFloat(k_Key, 0f), MinOffset, MaxOffset);
                    s_Loaded = true;
                }
                return s_Offset;
            }
            set
            {
                var clamped = Mathf.Clamp(value, MinOffset, MaxOffset);
                // Read the old value first, so the first set after launch doesn't skip the load.
                if (Mathf.Approximately(Offset, clamped))
                    return;
                s_Offset = clamped;
                PlayerPrefs.SetFloat(k_Key, clamped);
                PlayerPrefs.Save();
                Debug.Log($"[Stereo] Focus offset {clamped * 1000f:+0.0;-0.0;0.0} mm");
                Changed?.Invoke();
            }
        }

        // The viewer the lens math should use: the profile, with the carriage where it actually is.
        // The profile itself is left alone, so a rescan still starts from the viewer's own numbers.
        public static ViewerParams Apply(ViewerParams viewer)
        {
            if (viewer == null || Mathf.Approximately(Offset, 0f))
                return viewer;
            var adjusted = viewer.Clone();
            // Never let the lens reach the screen: the distortion divides by this distance.
            adjusted.screenToLensDistance = Mathf.Max(0.005f, viewer.screenToLensDistance + Offset);
            return adjusted;
        }

        public static void Reset() => Offset = 0f;
    }
}
