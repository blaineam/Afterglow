using System.Runtime.InteropServices;

namespace Afterglow.Stereo
{
    // What iOS says about the device (Plugins/iOS/AfterglowDeviceState.mm). Unity's iOS player
    // lowers the frame rate by itself when the thermal state gets serious, and tells scripts nothing:
    // on the iPhone 15 Pro the frame rate once fell from 120 to exactly 30 with the main thread idle,
    // and only Unity's console showed why. Only in iOS players; elsewhere it reports nothing.
    public static class DeviceState
    {
#if UNITY_IOS && !UNITY_EDITOR
        public static bool Supported => true;
        public static string ThermalState => Afterglow_ThermalState() switch
        {
            0 => "nominal",
            1 => "fair",
            2 => "serious",
            3 => "critical",
            var other => other.ToString(),
        };
        public static int ScreenMaximumFramesPerSecond => Afterglow_ScreenMaximumFramesPerSecond();

        [DllImport("__Internal")] static extern int Afterglow_ThermalState();
        [DllImport("__Internal")] static extern int Afterglow_ScreenMaximumFramesPerSecond();
#else
        public static bool Supported => false;
        public static string ThermalState => "";
        public static int ScreenMaximumFramesPerSecond => 0;
#endif
    }
}
