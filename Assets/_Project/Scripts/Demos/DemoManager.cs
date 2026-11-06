using System.Collections;
using Afterglow.Hands;
using Afterglow.Stereo;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Afterglow.Demos
{
    // Moves between the Home scene and the apps. The Core scene (rig, AR, hands, gaze) stays loaded
    // the whole time, so tracking, placed anchors and the viewer's calibration carry across; Home and
    // each app are scenes loaded on top of it and unloaded on leaving. Entering an app switches Core
    // to what the app needs (DemoRequirements) and leaving puts back what was on before, so Home is as
    // the user left it. Going straight from one app to another goes straight from one's needs to the
    // next's, from what was on before the first: putting Home's 3DoF back in between turned AR off
    // and on again, which restarted tracking. The "demo" launch option (an index into the catalog)
    // starts in an app instead of Home. Apps are picked on the home screen (HomeScreen), from Home or
    // from another app. An app that needs the room's surfaces (ScanSurfaces) scans the room as it
    // opens, with RoomScanPrompt showing what's found; nothing waits on the scan, which used to block
    // every cold start in the lobby. Nothing is placed on surfaces at Home, and entering an app starts
    // it with no objects placed. Lives in the Core scene.
    public class DemoManager : MonoBehaviour
    {
        [SerializeField] DemoCatalog m_Catalog;
        [SerializeField] CoreServices m_Core;
        [Tooltip("The view fades through black between scenes, rather than cutting.")]
        [SerializeField] ScreenFade m_Fade;
        [Tooltip("Optional: shows the room scan's progress over an app that scans as it opens.")]
        [SerializeField] RoomScanPrompt m_ScanPrompt;

        string m_LoadedScene;
        DemoCatalog.Entry m_Current;
        CoreState m_BeforeDemo;
        GameObject m_DefaultPrefab;
        bool m_Busy;
        Coroutine m_Fading;

        // Fading out of a scene, quickly, then into the next more slowly, once it has started.
        const float k_FadeOutSeconds = 0.3f;
        const float k_FadeInSeconds = 0.5f;

        public DemoCatalog Catalog => m_Catalog;
        // The app running now, or null at Home.
        public DemoCatalog.Entry Current => m_Current;
        // What the app running now was entered with (Enter), or null: a word from the home screen,
        // such as HomeScreen.k_FilesArgument, which the app reads in OnDemoEnter.
        public string Argument { get; private set; }

        // An app (or Home, null) finished loading.
        public event System.Action<DemoCatalog.Entry> Loaded;

        // A frame after Core's own Start, so the launch options for 6DoF and passthrough have applied
        // before an app overrides them.
        IEnumerator Start()
        {
            yield return null;
            if (m_Catalog == null)
            {
                Debug.LogError("[Demos] No demo catalog, so no Home or apps");
                yield break;
            }
            m_DefaultPrefab = m_Core.Placer.ObjectPrefab;
            m_Core.Placer.ObjectPrefab = null;
            var index = LaunchOptions.GetInt("demo", -1);
            if (m_Catalog.TryGet(index, out var entry))
            {
                Debug.Log($"[Demos] Starting in demo {index} ({entry.Id}), from the launch option");
                yield return Switch(entry, null);
            }
            else
            {
                if (index >= 0)
                    Debug.LogWarning($"[Demos] No demo {index}: the catalog has {m_Catalog.Demos.Count}");
                // Home starts in 6DoF passthrough unless the "dof 3" setting asks for 3DoF.
                if (Settings.Int("dof", 6) == 6)
                {
                    var state = CoreState.Resolve(m_Core.State, m_Catalog.HomeRequirements);
                    Debug.Log($"[Demos] Starting Home in {state}");
                    m_Core.Apply(state);
                }
                yield return Switch(null, null);
            }
        }

        public void Enter(int index)
        {
            if (m_Catalog.TryGet(index, out var entry))
                Enter(entry);
        }

        // argument: a word for the app, kept in Argument while it runs.
        public void Enter(DemoCatalog.Entry entry, string argument = null)
        {
            if (m_Busy || (entry == m_Current && argument == Argument))
                return;
            StartCoroutine(Switch(entry, argument));
        }

        // The home screen's Leave, and an app's own way out.
        public void ExitToHome()
        {
            if (m_Busy || m_Current == null)
                return;
            StartCoroutine(Switch(null, null));
        }

        // Whether entering an app should scan the room: it asks for surfaces, 6DoF is on to find them,
        // the room hasn't been scanned since 6DoF began, and the "scan" setting allows it. Pure, for
        // testing.
        public static bool WantsScan(DemoRequirements needs, CoreState state, bool hasScannedRoom, bool scanSetting) =>
            needs.ScanSurfaces && state.SixDof && !hasScannedRoom && scanSetting;

        // Unloads what's loaded and loads the app, or Home for null.
        IEnumerator Switch(DemoCatalog.Entry next, string argument)
        {
            m_Busy = true;
            var started = Time.realtimeSinceStartup;
            // The first scene comes up out of black; any later one fades the last out first.
            if (m_Fade != null)
            {
                StopFade();
                if (m_LoadedScene == null)
                    m_Fade.Alpha = 1f;
                else
                    yield return m_Fade.FadeTo(1f, k_FadeOutSeconds);
            }
            var fromDemo = m_Current != null;
            yield return Unload(restore: next == null);

            var scanning = false;
            if (next != null)
            {
                // From Home, what to put back on leaving; from another app, that's kept.
                if (!fromDemo)
                    m_BeforeDemo = m_Core.State;
                var state = CoreState.Resolve(m_BeforeDemo, next.Requirements);
                Debug.Log($"[Demos] Entering {next.Id}: {state} (was {m_BeforeDemo})");
                // Anything an app kept on leaving doesn't carry into the next one.
                m_Core.Placer.RemoveAll();
                // Cubes, unless the app chooses something else in OnDemoEnter.
                m_Core.Placer.ObjectPrefab = m_DefaultPrefab;
                m_Core.Apply(state);
                // Unless an earlier scan already covered the room.
                if (WantsScan(next.Requirements, state, m_Core.Boundary.HasScannedRoom, Settings.Int("scan", 1) != 0))
                {
                    m_Core.Boundary.ScanRoom();
                    scanning = true;
                }
            }

            var path = next != null ? next.ScenePath : m_Catalog.HomeScenePath;
            var loading = SceneManager.LoadSceneAsync(path, LoadSceneMode.Additive);
            if (loading == null)
            {
                Debug.LogError($"[Demos] Couldn't load {path}: is it in the build?");
                m_Busy = false;
                if (m_Fade != null)
                    m_Fade.Alpha = 0f;
                yield break;
            }
            yield return loading;

            var scene = SceneManager.GetSceneByPath(path);
            // What the app creates goes into its own scene, so unloading it cleans up.
            SceneManager.SetActiveScene(scene);
            m_LoadedScene = path;
            m_Current = next;
            Argument = next != null ? argument : null;
            foreach (var demo in Demos(scene))
                demo.OnDemoEnter(m_Core);
            Debug.Log($"[Demos] {(next != null ? next.Title : "Home")} loaded in {Time.realtimeSinceStartup - started:F1} s" +
                      (Argument != null ? $" with \"{Argument}\"" : ""));
            m_Busy = false;
            Loaded?.Invoke(next);
            // After Loaded: the prompt hides on any load, then shows for this one.
            if (scanning && m_ScanPrompt != null)
                m_ScanPrompt.Show();
            if (m_Fade != null)
                m_Fading = StartCoroutine(FadeIn());
        }

        // A couple of frames late, so the scene and any mode change it made have drawn.
        IEnumerator FadeIn()
        {
            yield return null;
            yield return null;
            yield return m_Fade.FadeTo(0f, k_FadeInSeconds);
            m_Fading = null;
        }

        void StopFade()
        {
            if (m_Fading != null)
                StopCoroutine(m_Fading);
            m_Fading = null;
        }

        // restore: put back what was on before the app being left; not when another app follows.
        IEnumerator Unload(bool restore)
        {
            // The settings panel was opened for the scene being left.
            if (m_Core.Settings != null)
                m_Core.Settings.Close();
            if (m_LoadedScene == null)
                yield break;

            var scene = SceneManager.GetSceneByPath(m_LoadedScene);
            foreach (var demo in Demos(scene))
                demo.OnDemoExit(m_Core);

            var leaving = m_Current;
            m_Current = null;
            Argument = null;
            m_LoadedScene = null;
            if (leaving != null)
            {
                if (!leaving.Requirements.KeepPlacedObjects)
                    m_Core.Placer.RemoveAll();
                m_Core.Placer.ObjectPrefab = null;
                PinchRouter.Clear();
                if (restore)
                {
                    Debug.Log($"[Demos] Leaving {leaving.Id}: back to {m_BeforeDemo}");
                    m_Core.Apply(m_BeforeDemo);
                }
                else
                {
                    Debug.Log($"[Demos] Leaving {leaving.Id} for another app");
                }
            }

            SceneManager.SetActiveScene(gameObject.scene);
            yield return SceneManager.UnloadSceneAsync(scene);
            // App assets, such as a video's textures, are only unloaded once nothing refers to them.
            yield return Resources.UnloadUnusedAssets();
        }

        static Demo[] Demos(Scene scene)
        {
            if (!scene.IsValid() || !scene.isLoaded)
                return System.Array.Empty<Demo>();
            var found = new System.Collections.Generic.List<Demo>();
            foreach (var root in scene.GetRootGameObjects())
                found.AddRange(root.GetComponentsInChildren<Demo>());
            return found.ToArray();
        }
    }
}
