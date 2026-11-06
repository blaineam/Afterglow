using UnityEngine;
using UnityEngine.XR.ARFoundation;
using UnityEngine.XR.Management;

namespace Afterglow.Stereo
{
    // What this build, on this machine, can actually do. Decided from what XR Plug-in Management
    // managed to start rather than from the platform: an iPhone has ARKit, but the iOS Simulator
    // builds as iOS and has none, and the Editor has 6DoF only when XR Simulation is switched on.
    //
    // Everything that needs the camera -- 6DoF, passthrough, hands -- asks this before switching
    // on, so a build without an AR provider runs flat in 3DoF with mouse or touch to look around
    // (DeskHeadLook) instead of waiting for tracking that is never going to start.
    public static class Capabilities
    {
        // Whether an AR provider is running, which is what 6DoF, passthrough and hand tracking
        // all stand on. XR initializes before the first scene loads (InitManagerOnStart), so by
        // the time anything asks, the answer is settled.
        //
        // The loader alone is not enough to go on: in the iOS Simulator the ARKit loader starts
        // happily and the session then throws on its first update, because the Simulator has no
        // ARKit (its session reports Unsupported, but only after it has been asked). So the
        // Simulator is recognised up front by its device model, which is the Mac's architecture
        // rather than an iPhone's name, and an Unsupported session is honoured once it says so.
        public static bool SixDof
        {
            get
            {
                if (IsSimulator)
                    return false;
                if (ARSession.state == ARSessionState.Unsupported)
                    return false;
                var settings = XRGeneralSettings.Instance;
                return settings != null && settings.Manager != null && settings.Manager.activeLoader != null;
            }
        }

        // An iOS build running in the Simulator. Not by the device model: Unity reports the
        // simulated phone's there (iPhone19,3), which is no help. CoreSimulator sets SIMULATOR_UDID
        // (and friends) in every process it launches, and nothing else does.
        public static bool IsSimulator =>
            Application.platform == RuntimePlatform.IPhonePlayer &&
            !string.IsNullOrEmpty(System.Environment.GetEnvironmentVariable("SIMULATOR_UDID"));

        public static string Describe() => SixDof
            ? "AR provider running"
            : IsSimulator ? "this is the iOS Simulator, which has no ARKit, so 3DoF only: no passthrough, no hands, no surfaces"
            : ARSession.state == ARSessionState.Unsupported ? "the AR session says this device is unsupported, so 3DoF only"
            : "no AR provider, so 3DoF only: no passthrough, no hands, no surfaces";
    }
}
