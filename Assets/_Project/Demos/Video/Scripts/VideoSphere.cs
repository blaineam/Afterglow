using System;
using UnityEngine;
using UnityEngine.EventSystems;

namespace CardboardXR.Demos.Video
{
    // The surface a video is drawn on: a large sphere around the viewer, its front half, or a flat
    // screen ahead of them, textured from the inside. A 3D video gets one per eye, each on a layer only that eye's
    // camera draws (StereoRig.LeftEyeOnlyLayer and RightEyeOnlyLayer) and showing that eye's part
    // of the frame. It stays centered on the head, turning with nothing, so moving the phone never
    // shows the video as a ball around you: only turning looks around. While a video shows, the
    // whole sphere is clickable (Clicked), for toggling the controls with a tap anywhere.
    public class VideoSphere : MonoBehaviour
    {
        const int k_Rings = 48;
        const int k_Segments = 96;

        [Tooltip("An unlit material whose main texture the video is drawn into. Copied for each eye.")]
        [SerializeField] Material m_Material;
        [Tooltip("Meters. Beyond anything else drawn in the demo, such as its panels, and within the gaze's reach " +
                 "(GazePointer's max distance, 20 m) so a tap on it registers.")]
        [SerializeField] float m_Radius = 15f;
        [Tooltip("Degrees. How wide a flat screen looks: the angle it spans from the viewer. The lenses " +
                 "show about 60 degrees to each side, so a screen wider than that runs past the edge of " +
                 "the view; this is a cinema-sized picture with room around it.")]
        [SerializeField] float m_FlatWidthDegrees = 60f;

        readonly MeshRenderer[] m_Eyes = new MeshRenderer[2];
        readonly Material[] m_Materials = new Material[2];
        Mesh m_Full;
        Mesh m_Half;
        Mesh m_Flat;
        GameObject m_ClickSurface;

        // A tap or pinch with the gaze on the video, rather than on a panel.
        public event Action Clicked;

        void Awake()
        {
            m_Full = BuildMesh(Projection.Full360, m_Radius);
            m_Half = BuildMesh(Projection.Half180, m_Radius);
            m_Flat = BuildFlatMesh(m_Radius);
            for (var eye = 0; eye < 2; eye++)
            {
                var eyeObject = new GameObject(eye == 0 ? "Left Eye" : "Right Eye");
                eyeObject.transform.SetParent(transform, false);
                eyeObject.AddComponent<MeshFilter>();
                m_Eyes[eye] = eyeObject.AddComponent<MeshRenderer>();
                m_Eyes[eye].shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
                m_Eyes[eye].receiveShadows = false;
                m_Materials[eye] = new Material(m_Material) { name = $"Video {eyeObject.name}" };
                m_Eyes[eye].sharedMaterial = m_Materials[eye];
                eyeObject.SetActive(false);
            }

            // Always the whole sphere, so a tap anywhere counts, even outside a 180 video. It faces
            // inward, which is the side the gaze's ray meets.
            m_ClickSurface = new GameObject("Click Surface");
            m_ClickSurface.transform.SetParent(transform, false);
            m_ClickSurface.AddComponent<MeshCollider>().sharedMesh = m_Full;
            m_ClickSurface.AddComponent<ClickRelay>().Clicked += () => Clicked?.Invoke();
            m_ClickSurface.SetActive(false);
        }

        void OnDestroy()
        {
            foreach (var material in m_Materials)
                Destroy(material);
            Destroy(m_Full);
            Destroy(m_Half);
            Destroy(m_Flat);
        }

        void LateUpdate()
        {
            var core = CoreServices.Instance;
            if (core != null)
                transform.SetPositionAndRotation(core.Head.position, Quaternion.identity);
        }

        // Shows the texture in the format, or hides the surface for null.
        public void Show(Texture texture, VideoFormat format) => Show(texture, format, null);

        // One picture per eye, for a source that decodes a texture for each (a spatial photo or
        // video, whose two views are separate layers of one file) rather than one frame holding
        // both. With no right texture the format's halves of the left one are used, which is how
        // side-by-side and top/bottom files are drawn.
        public void Show(Texture leftTexture, VideoFormat format, Texture rightTexture)
        {
            var showing = leftTexture != null;
            // Two textures are stereo whatever the layout says, since each eye has its own picture.
            var stereo = showing && (rightTexture != null || format.IsStereo);
            m_ClickSurface.SetActive(showing);
            for (var eye = 0; eye < 2; eye++)
            {
                var shown = showing && (eye == 0 || stereo);
                m_Eyes[eye].gameObject.SetActive(shown);
                if (!shown)
                    continue;
                // A 2D video is on the ordinary layer, for both eyes; a 3D one gives each eye its own.
                m_Eyes[eye].gameObject.layer = !stereo ? 0
                    : eye == 0 ? Stereo.StereoRig.LeftEyeOnlyLayer : Stereo.StereoRig.RightEyeOnlyLayer;
                m_Eyes[eye].GetComponent<MeshFilter>().sharedMesh = format.Projection switch
                {
                    Projection.Full360 => m_Full,
                    Projection.Half180 => m_Half,
                    _ => m_Flat,
                };

                // With a texture each, an eye sees all of its own; otherwise its half of the one.
                var texture = eye == 0 ? leftTexture : rightTexture ?? leftTexture;
                var rect = rightTexture != null ? new Rect(0f, 0f, 1f, 1f) : format.EyeRect(eye);
                m_Materials[eye].mainTexture = texture;
                m_Materials[eye].mainTextureScale = rect.size;
                m_Materials[eye].mainTextureOffset = rect.position;

                // The spheres are already the right size; a flat screen is a unit quad, sized here
                // so it spans m_FlatWidthDegrees and keeps the picture's own shape.
                m_Eyes[eye].transform.localScale = format.Projection == Projection.Flat
                    ? FlatScale(texture, rect)
                    : Vector3.one;
            }
        }

        // How big the flat screen has to be, at m_Radius, to span m_FlatWidthDegrees without
        // stretching the picture.
        Vector3 FlatScale(Texture texture, Rect eyeRect)
        {
            var width = 2f * m_Radius * Mathf.Tan(0.5f * m_FlatWidthDegrees * Mathf.Deg2Rad);
            var pixelWidth = texture != null ? texture.width * eyeRect.width : 0f;
            var pixelHeight = texture != null ? texture.height * eyeRect.height : 0f;
            // A texture with no size yet (a video still opening) gets 16:9 rather than a zero scale.
            var aspect = pixelWidth > 0f && pixelHeight > 0f ? pixelWidth / pixelHeight : 16f / 9f;
            return new Vector3(width, width / aspect, 1f);
        }

        // The texture coordinate for a direction given as longitude (0 ahead, positive to the right)
        // and latitude (positive up), in radians. Equirectangular: across is longitude and up is
        // latitude, with straight ahead in the middle of the frame. A 180 video spans only the
        // front half.
        public static Vector2 Uv(float longitude, float latitude, Projection projection)
        {
            var span = projection == Projection.Full360 ? 2f * Mathf.PI : Mathf.PI;
            return new Vector2(0.5f + longitude / span, 0.5f + latitude / Mathf.PI);
        }

        public static Vector3 Direction(float longitude, float latitude) =>
            new(Mathf.Cos(latitude) * Mathf.Sin(longitude), Mathf.Sin(latitude), Mathf.Cos(latitude) * Mathf.Cos(longitude));

        // A screen ahead of the viewer: a unit quad at `distance`, half a meter across, facing back
        // toward the origin so it is seen from where the head is. Show scales it to the size it
        // should look.
        public static Mesh BuildFlatMesh(float distance)
        {
            var mesh = new Mesh
            {
                name = "Video Screen",
                vertices = new[]
                {
                    new Vector3(-0.5f, -0.5f, distance),
                    new Vector3(-0.5f, 0.5f, distance),
                    new Vector3(0.5f, 0.5f, distance),
                    new Vector3(0.5f, -0.5f, distance),
                },
                uv = new[] { new Vector2(0f, 0f), new Vector2(0f, 1f), new Vector2(1f, 1f), new Vector2(1f, 0f) },
                // Wound so the face's normal points back along -z, at the viewer.
                triangles = new[] { 0, 1, 2, 0, 2, 3 },
            };
            mesh.RecalculateNormals();
            mesh.RecalculateBounds();
            return mesh;
        }

        // A sphere or its front half, facing inward. The seam repeats its column of vertices so the
        // texture doesn't wrap backwards across one strip.
        public static Mesh BuildMesh(Projection projection, float radius)
        {
            var half = projection == Projection.Half180;
            var segments = half ? k_Segments / 2 : k_Segments;
            var span = half ? Mathf.PI : 2f * Mathf.PI;
            var vertices = new Vector3[(k_Rings + 1) * (segments + 1)];
            var uvs = new Vector2[vertices.Length];
            for (var ring = 0; ring <= k_Rings; ring++)
            {
                var latitude = -Mathf.PI / 2f + Mathf.PI * ring / k_Rings;
                for (var segment = 0; segment <= segments; segment++)
                {
                    var longitude = -span / 2f + span * segment / segments;
                    var index = ring * (segments + 1) + segment;
                    vertices[index] = Direction(longitude, latitude) * radius;
                    uvs[index] = Uv(longitude, latitude, projection);
                }
            }

            var triangles = new int[k_Rings * segments * 6];
            var t = 0;
            for (var ring = 0; ring < k_Rings; ring++)
            {
                for (var segment = 0; segment < segments; segment++)
                {
                    var a = ring * (segments + 1) + segment;
                    var b = a + segments + 1;
                    // Clockwise as seen from the center, which Unity draws as the front.
                    triangles[t++] = a;
                    triangles[t++] = b;
                    triangles[t++] = a + 1;
                    triangles[t++] = a + 1;
                    triangles[t++] = b;
                    triangles[t++] = b + 1;
                }
            }

            var mesh = new Mesh
            {
                name = half ? "Video Hemisphere" : "Video Sphere",
                indexFormat = UnityEngine.Rendering.IndexFormat.UInt32,
                vertices = vertices,
                uv = uvs,
                triangles = triangles,
            };
            mesh.RecalculateBounds();
            return mesh;
        }
    }

    // Passes a gaze click on this collider to whoever listens.
    public class ClickRelay : MonoBehaviour, IPointerClickHandler
    {
        public event Action Clicked;

        public void OnPointerClick(PointerEventData eventData) => Clicked?.Invoke();
    }
}
