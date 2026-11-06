#if UNITY_IOS
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEditor.iOS.Xcode;
using UnityEngine;

namespace ProjectBootstrap
{
    // System frameworks the native plugins need, which Unity doesn't link by itself.
    //
    // A plugin that imports a framework's headers compiles happily without it: the header is found
    // on the SDK's include path whether or not anything links the library. It is the linker that
    // objects, and only at the end of a full iOS build, with "Undefined symbols ... referenced
    // from AfterglowWebXR.o". Nothing earlier -- not the Editor's own compile, not the EditMode
    // tests, not Unity's export -- says a word about it.
    //
    //   WebKit        the in-app browser's WKWebView (AfterglowWebXR.mm)
    //   Photos        the photo and video library (AfterglowPhotoLibrary.mm)
    //   Speech        dictation into the browser (AfterglowDictation.mm)
    //   AVFoundation  the microphone that feeds it, and the player that decodes both layers of a
    //                 spatial video (AfterglowSpatialVideo.mm)
    //   CoreMedia     the tagged buffer groups a spatial video's two eyes arrive in, same plugin
    //   CoreVideo     the pixel buffers inside them, and the Metal texture cache that wraps those
    //   Metal         the textures themselves, which Unity draws from without a copy
    //   Vision        hand pose on the Neural Engine (AfterglowHandPose.mm)
    //   Accelerate    vImage, which turns the app's RGBA image into the BGRA buffer Vision takes
    //
    // They go on UnityFramework, which is the target the plugins are compiled into; adding them to
    // Unity-iPhone instead links them into the shell app, where the plugins are not.
    public class IosFrameworks : IPostprocessBuildWithReport
    {
        // After IosProMotion, which only touches the plist.
        public int callbackOrder => 1;

        static readonly string[] k_Frameworks =
        {
            "WebKit.framework", "Photos.framework", "Speech.framework", "AVFoundation.framework",
            "CoreMedia.framework", "CoreVideo.framework", "Metal.framework", "Vision.framework",
            "Accelerate.framework",
        };

        public void OnPostprocessBuild(BuildReport report)
        {
            if (report.summary.platform != BuildTarget.iOS)
                return;

            var path = PBXProject.GetPBXProjectPath(report.summary.outputPath);
            var project = new PBXProject();
            project.ReadFromFile(path);
            var target = project.GetUnityFrameworkTargetGuid();
            foreach (var framework in k_Frameworks)
                project.AddFrameworkToProject(target, framework, false);
            project.WriteToFile(path);
            Debug.Log($"[ProjectSetup] Linked {string.Join(", ", k_Frameworks)} into UnityFramework.");
        }
    }
}
#endif
