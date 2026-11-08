using System.Runtime.InteropServices;
using System.Text;

namespace Afterglow.Demos.Video
{
    // iOS's document picker (Plugins/iOS/AfterglowFilePicker.mm): photos and videos from anywhere
    // the Files app reaches, copied into the app's Media folder, which the browser then lists.
    // iOS only; elsewhere Supported is false and the browser's Import button stays hidden, since
    // the folder can be filled from a computer instead.
    public static class FilePicker
    {
        public enum Result
        {
            Nothing,
            Imported,
            Cancelled,
        }

        const int k_PathLength = 1024;

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        public static bool IsOpen =>
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_FilePickerIsOpen() != 0;
#else
            false;
#endif

        // Opens the picker; picks land in the folder. False if it couldn't open.
        public static bool Present(string folder)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_FilePickerPresent(folder) != 0;
#else
            return false;
#endif
        }

        // The next imported file, if one has arrived; Cancelled once after a pick came to nothing.
        public static Result TryTake(out string path)
        {
            path = null;
#if UNITY_IOS && !UNITY_EDITOR
            var buffer = new StringBuilder(k_PathLength);
            var state = Afterglow_FilePickerTake(buffer, buffer.Capacity);
            if (state > 0)
            {
                path = buffer.ToString();
                return Result.Imported;
            }
            return state < 0 ? Result.Cancelled : Result.Nothing;
#else
            return Result.Nothing;
#endif
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_FilePickerPresent(string folder);
        [DllImport("__Internal")] static extern int Afterglow_FilePickerIsOpen();
        [DllImport("__Internal")] static extern int Afterglow_FilePickerTake(StringBuilder path, int pathLength);
#endif
    }
}
