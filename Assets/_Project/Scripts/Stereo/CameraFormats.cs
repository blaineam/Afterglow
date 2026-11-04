using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace CardboardXR.Stereo
{
    // What camera formats ARKit will give a world-tracking session here
    // (Plugins/iOS/CardboardXRVideoFormats.mm).
    //
    // Worth knowing because the camera's field of view is this app's tightest constraint: the main
    // lens sees about 68 degrees across and 42 up and down, and a hand reaching for something
    // leaves the frame more often than not. The ultra-wide lens would roughly double that. Apple
    // documents picking it for face tracking; whether world tracking offers it is not documented,
    // and AR Foundation's own configuration list leaves out the one field that would say.
    public static class CameraFormats
    {
        const int k_Length = 2048;

        public static void Log()
        {
#if UNITY_IOS && !UNITY_EDITOR
            var text = new StringBuilder(k_Length);
            var count = CardboardXR_VideoFormats(text, text.Capacity);
            if (count <= 0)
            {
                Debug.Log("[Camera] ARKit offered no world-tracking video formats to choose from.");
                return;
            }
            Debug.Log($"[Camera] {count} world-tracking video formats:\n{text}");
#endif
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int CardboardXR_VideoFormats(StringBuilder formats, int length);
#endif
    }
}
