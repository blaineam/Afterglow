#if UNITY_IOS
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.iOS.Xcode;
using UnityEngine;

namespace ProjectBootstrap
{
    // Info.plist settings Unity has no option for. Lets the app draw faster than 60 fps on a
    // ProMotion iPhone, shares its Documents folder so videos can be copied in, and says why the
    // app reads the Photos library, which it does to show spatial photos. Without
    // CADisableMinimumFrameDuration, CoreAnimation holds every app to a frame duration of 1/60 s
    // however high Application.targetFrameRate is, and the iPhone 15 Pro's 120 Hz display goes to
    // waste. Unity writes the key as false, so this sets it once the Xcode project exists.
    public class IosProMotion : IPostprocessBuildWithReport
    {
        public int callbackOrder => 0;

        public void OnPostprocessBuild(BuildReport report)
        {
            if (report.summary.platform != BuildTarget.iOS)
                return;

            var path = Path.Combine(report.summary.outputPath, "Info.plist");
            if (!File.Exists(path))
            {
                Debug.LogWarning($"[ProjectSetup] No Info.plist at {path}; the display stays at 60 fps.");
                return;
            }

            var plist = new PlistDocument();
            plist.ReadFromFile(path);
            // Both: the second is the one that counts on iPhones, the first on iPads.
            plist.root.SetBoolean("CADisableMinimumFrameDuration", true);
            plist.root.SetBoolean("CADisableMinimumFrameDurationOnPhone", true);
            // The app's Documents folder shows in Finder (the phone's Files tab) and the Files app,
            // so videos can be copied into Documents/Videos for the video demo.
            plist.root.SetBoolean("UIFileSharingEnabled", true);
            plist.root.SetBoolean("LSSupportsOpeningDocumentsInPlace", true);
            // The browser shows whatever page the user opens, plain HTTP included, which App
            // Transport Security otherwise blocks inside a web view; this is the key Apple
            // provides for exactly that, and it covers the web view's content only, nothing the
            // app itself fetches.
            plist.root.CreateDict("NSAppTransportSecurity").SetBoolean("NSAllowsArbitraryLoadsInWebContent", true);
            // iOS kills the app the moment the Photos library is read unless it can say why. There
            // is no PlayerSettings option for this one, unlike the camera's.
            plist.root.SetString("NSPhotoLibraryUsageDescription",
                "Afterglow shows the photos and videos in your library through the viewer: spatial photos in 3D, panoramas and 360 stills all around you.");
            // Dictation into the browser, which needs both: recognition and the microphone that
            // feeds it. Said here rather than through PlayerSettings because the build method
            // does not run ProjectSetup.Apply, so anything set there can be missing from a build.
            plist.root.SetString("NSSpeechRecognitionUsageDescription",
                "Afterglow turns what you say into text for the browser. Recognition happens on " +
                "this iPhone and your voice is not sent anywhere.");
            plist.root.SetString("NSMicrophoneUsageDescription",
                "Afterglow listens only while you hold the dictate button, to type what you say " +
                "into the browser.");
            plist.WriteToFile(path);

            // The browser's saved logins live in the Keychain, which refuses an app without a
            // keychain-access-groups entitlement (errSecMissingEntitlement, -34018). The app's own
            // group is the one every app may use; Xcode's automatic signing carries it.
            var project = Path.Combine(report.summary.outputPath, "Unity-iPhone.xcodeproj", "project.pbxproj");
            if (File.Exists(project))
            {
                var pbx = new PBXProject();
                pbx.ReadFromFile(project);
                var capabilities = new ProjectCapabilityManager(project, "Unity-iPhone/Afterglow.entitlements",
                    targetGuid: pbx.GetUnityMainTargetGuid());
                capabilities.AddKeychainSharing(new[] { "$(AppIdentifierPrefix)" + PlayerSettings.applicationIdentifier });
                capabilities.WriteToFile();
            }
            Debug.Log("[ProjectSetup] ProMotion allowed: the display can run above 60 fps. " +
                      "Documents shared with Finder and Files, the Photos library can be read, " +
                      "and dictation can ask for the microphone.");
        }
    }
}
#endif
