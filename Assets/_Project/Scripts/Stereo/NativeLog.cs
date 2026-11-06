using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace Afterglow.Stereo
{
    // Collects the iOS plugins' log lines (Plugins/iOS/AfterglowNativeLog.mm) every frame and
    // writes them through Unity's log, so they reach the session log with their own tags
    // ([Photos], [Spatial], [WebXR], [Files]) beside the app's lines. Without this they went only
    // to the system log, and what a plugin did on the phone could not be read back from the log
    // file. Lives on the head, in Core, so it runs in every scene.
    public class NativeLog : MonoBehaviour
    {
        const int k_LineLength = 2048;
        // Lines drained in one frame, so a flood can't stall it.
        const int k_PerFrame = 64;

        void Update()
        {
#if UNITY_IOS && !UNITY_EDITOR
            if (Afterglow_NativeLogCount() == 0)
                return;
            for (var i = 0; i < k_PerFrame; i++)
            {
                // A fresh builder per line: IL2CPP copies nothing back into one that was emptied
                // with Length = 0 (every line came through blank), and lines are rare.
                var buffer = new StringBuilder(k_LineLength);
                if (Afterglow_NativeLogTake(buffer, buffer.Capacity) == 0)
                    return;
                var line = buffer.ToString();
                // A plugin's own tag goes through as is; anything untagged is marked as native.
                Debug.Log(line.StartsWith("[") ? line : "[Native] " + line);
            }
#endif
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_NativeLogCount();
        [DllImport("__Internal")] static extern int Afterglow_NativeLogTake(StringBuilder line, int lineLength);
#endif
    }
}
