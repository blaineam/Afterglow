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
    // from CardboardXRWebXR.o". Nothing earlier -- not the Editor's own compile, not the EditMode
    // tests, not Unity's export -- says a word about it.
    //
    //   WebKit  the in-app browser's WKWebView (CardboardXRWebXR.mm)
    //   Photos  the spatial photo library (CardboardXRSpatialPhotos.mm)
    //
    // They go on UnityFramework, which is the target the plugins are compiled into; adding them to
    // Unity-iPhone instead links them into the shell app, where the plugins are not.
    public class IosFrameworks : IPostprocessBuildWithReport
    {
        // After IosProMotion, which only touches the plist.
        public int callbackOrder => 1;

        static readonly string[] k_Frameworks = { "WebKit.framework", "Photos.framework" };

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
            Debug.Log($"[ProjectSetup] Linked {string.Join(" and ", k_Frameworks)} into UnityFramework.");
        }
    }
}
