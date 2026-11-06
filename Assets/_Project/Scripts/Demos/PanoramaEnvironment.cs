using System;
using System.IO;
using System.Linq;
using Afterglow.Stereo;
using UnityEngine;

namespace Afterglow.Demos
{
    // Your own 360 photo as the surroundings: any equirectangular image in the app's
    // Documents/Environments folder (Finder's Files tab, or the Files app), chosen in Settings
    // under "Environment". A sphere around the head wears it and the built-in environment hides
    // while it does; passthrough hides both, as it hides any virtual surroundings. Makes itself
    // when the app starts and lives across scene loads, so nothing in a scene has to know.
    public class PanoramaEnvironment : MonoBehaviour
    {
        public const string FolderName = "Environments";
        public const string SettingKey = "environment";
        const float k_Radius = 60f;
        const int k_Segments = 96;
        const int k_Rings = 48;
        static readonly string[] k_Extensions = { ".jpg", ".jpeg", ".png" };

        public static string Folder => Path.Combine(Application.persistentDataPath, FolderName);

        // The photos on offer, in name order, so a setting's number means the same photo next time
        // as long as nothing was added before it.
        public static string[] Files()
        {
            try
            {
                Directory.CreateDirectory(Folder);
                return Directory.GetFiles(Folder)
                    .Where(f => k_Extensions.Contains(Path.GetExtension(f).ToLowerInvariant()))
                    .OrderBy(f => Path.GetFileName(f), StringComparer.OrdinalIgnoreCase)
                    .ToArray();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Debug.LogWarning($"[Environment] Couldn't list {Folder}: {e.Message}");
                return Array.Empty<string>();
            }
        }

        // What a setting's value means: 0 the built-in environment, n the nth photo.
        public static string Describe(int choice, string[] files) =>
            choice <= 0 || choice > files.Length ? "Synthwave" : Path.GetFileNameWithoutExtension(files[choice - 1]);

        static PanoramaEnvironment s_Instance;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Create()
        {
            if (s_Instance != null)
                return;
            var go = new GameObject("Panorama Environment");
            DontDestroyOnLoad(go);
            s_Instance = go.AddComponent<PanoramaEnvironment>();
        }

        GameObject m_Sphere;
        Material m_Material;
        Texture2D m_Texture;
        string m_Shown;

        void OnEnable()
        {
            Settings.Changed += OnSetting;
            Apply(Settings.Int(SettingKey, 0));
        }

        void OnDisable()
        {
            Settings.Changed -= OnSetting;
            Show(null);
        }

        void OnSetting(string name)
        {
            if (name == SettingKey)
                Apply(Settings.Saved(SettingKey, 0));
        }

        void Apply(int choice)
        {
            var files = Files();
            if (choice <= 0 || choice > files.Length)
            {
                if (choice > files.Length && choice > 0)
                    Debug.Log($"[Environment] Photo {choice} asked for, but there are {files.Length} in {FolderName}; the built-in environment shows");
                Show(null);
                return;
            }
            Show(files[choice - 1]);
        }

        void Show(string path)
        {
            if (path == m_Shown)
                return;
            m_Shown = path;
            if (path == null)
            {
                if (m_Sphere != null)
                    m_Sphere.SetActive(false);
                VirtualEnvironment.SetReplaced(false);
                Debug.Log("[Environment] The built-in environment");
                return;
            }
            byte[] bytes;
            try
            {
                bytes = File.ReadAllBytes(path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Debug.LogWarning($"[Environment] Couldn't read {Path.GetFileName(path)}: {e.Message}");
                m_Shown = null;
                return;
            }
            if (m_Texture == null)
                m_Texture = new Texture2D(2, 2, TextureFormat.RGB24, true) { name = "Panorama", wrapMode = TextureWrapMode.Repeat, filterMode = FilterMode.Trilinear };
            if (!m_Texture.LoadImage(bytes, false))
            {
                Debug.LogWarning($"[Environment] {Path.GetFileName(path)} isn't an image that can be shown");
                m_Shown = null;
                return;
            }
            EnsureSphere();
            m_Material.mainTexture = m_Texture;
            m_Sphere.SetActive(true);
            VirtualEnvironment.SetReplaced(true);
            Debug.Log($"[Environment] {Path.GetFileName(path)}, {m_Texture.width}x{m_Texture.height}, around you");
        }

        void EnsureSphere()
        {
            if (m_Sphere != null)
                return;
            var shader = Shader.Find("Universal Render Pipeline/Unlit");
            m_Material = new Material(shader) { name = "Panorama" };
            m_Sphere = new GameObject("Panorama Sphere");
            m_Sphere.transform.SetParent(transform, false);
            m_Sphere.AddComponent<MeshFilter>().sharedMesh = BuildSphere(k_Radius, k_Segments, k_Rings);
            var renderer = m_Sphere.AddComponent<MeshRenderer>();
            renderer.sharedMaterial = m_Material;
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            renderer.receiveShadows = false;
            // The passthrough controller hides every VirtualEnvironment; this one is the
            // replacement, shown instead of the built-in one rather than with it.
            m_Sphere.AddComponent<VirtualEnvironment>().IsReplacement = true;
        }

        void LateUpdate()
        {
            // Around the head, so walking never reaches the sphere's wall.
            var core = CoreServices.Instance;
            if (m_Sphere != null && m_Sphere.activeSelf && core != null && core.Fusion != null)
                m_Sphere.transform.position = core.Fusion.transform.position;
        }

        // A sphere seen from inside, with equirectangular texture coordinates: u around (the
        // picture's left edge straight behind, its middle straight ahead), v from the bottom up.
        // Pure, so it can be checked.
        public static Mesh BuildSphere(float radius, int segments, int rings)
        {
            var vertices = new Vector3[(segments + 1) * (rings + 1)];
            var uvs = new Vector2[vertices.Length];
            for (var r = 0; r <= rings; r++)
            {
                var v = (float)r / rings;
                var lat = (v - 0.5f) * Mathf.PI;
                for (var s = 0; s <= segments; s++)
                {
                    var u = (float)s / segments;
                    // Longitude runs the other way round from the usual, which is what turns the
                    // picture right way round when seen from inside.
                    var lon = (0.5f - u) * 2f * Mathf.PI;
                    var i = r * (segments + 1) + s;
                    vertices[i] = new Vector3(Mathf.Cos(lat) * Mathf.Sin(lon), Mathf.Sin(lat), Mathf.Cos(lat) * Mathf.Cos(lon)) * radius;
                    uvs[i] = new Vector2(u, v);
                }
            }
            var triangles = new int[segments * rings * 6];
            var t = 0;
            for (var r = 0; r < rings; r++)
            {
                for (var s = 0; s < segments; s++)
                {
                    var a = r * (segments + 1) + s;
                    var b = a + segments + 1;
                    // Wound to face inward.
                    triangles[t++] = a; triangles[t++] = a + 1; triangles[t++] = b;
                    triangles[t++] = a + 1; triangles[t++] = b + 1; triangles[t++] = b;
                }
            }
            var mesh = new Mesh { name = "Panorama Sphere", indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
            mesh.SetVertices(vertices);
            mesh.SetUVs(0, uvs);
            mesh.SetTriangles(triangles, 0);
            mesh.RecalculateBounds();
            return mesh;
        }
    }
}
