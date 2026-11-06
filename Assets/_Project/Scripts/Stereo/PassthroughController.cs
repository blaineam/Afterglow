using UnityEngine;
using UnityEngine.InputSystem.XR;
using UnityEngine.Rendering;
using Afterglow.UI;
using UnityEngine.XR.ARFoundation;

namespace Afterglow.Stereo
{
    // Camera passthrough in the viewer. Each new ARCore camera image is drawn with ARCore's own
    // background material into a texture, with its display transform widened so the texture holds
    // the whole camera image instead of the screen-shaped crop ARCore shows. A screen quad in front
    // of the eyes shows it at the angle the camera saw it, so the room appears at true scale. The
    // camera sees less than a Cardboard eye, so at true scale the image is a window with a dark
    // border; by default it is magnified, uniformly, to fill the view (the "ptFill" setting).
    // Passthrough needs 6DoF, since ARCore must run, and hides the virtual environment (every
    // VirtualEnvironment, in whichever scene).
    //
    // The image is always behind: it was taken 45-100 ms ago, and the head has moved since. The quad
    // is therefore not the picture, only the surface the picture is drawn on. It sits square to the
    // view, wide enough to cover the whole field of view, and the shader decides what each of its
    // pixels shows from the direction that pixel looks in, turned into the axes of the camera that
    // took the image (m_CaptureInSession). Depth drops out of that, and so does where the head is:
    // only which way it faces can move the picture.
    //
    // That last part is the point, and it is worth being exact about why, because the quad it
    // replaces was not wrong in the way it looks. That quad hung on the AR camera, covering that
    // camera's frustum at m_ShownDistance. Seen from the point the image was taken from, a flat
    // screen rigidly attached to the camera is an exact re-rendering however the head has turned:
    // turning the head only re-rasterizes it. So rotation was never the error.
    //
    // The error came in through the other end of the pose. The eye is not at the point the image was
    // taken from; it is at the position filter's prediction for now, and the image is from 45-100 ms
    // ago, so the two are a centimeter or two apart whenever the head is moving. Reprojecting onto a
    // plane at distance d is exact only for what really is d away, and everything else is thrown off
    // by about t * (1/Z - 1/d) radians, for an offset t and a true depth Z. With the plane at 2 m
    // that is a fraction of a degree. But PassthroughHandFocus pulls the plane in to 0.3 m whenever a
    // hand is up, and then 2 cm of offset swings a wall 3 m away through three and a half degrees
    // while the hand itself stays put: the picture stretches and pulls, in proportion to how fast the
    // head is moving. Tilting makes it worse again, because a tilt the gyro and ARCore disagree on
    // leaks gravity into the accelerations the filter integrates, so t itself grows.
    //
    // Reprojecting a direction takes d and t out of it together. What is given up is the parallax of
    // a move of the head, which the plane did carry for things at d: walk a meter a second and the
    // picture now sits about 7 cm behind, a couple of degrees of offset that slides with the body
    // rather than shearing with every twitch of it. That is the right trade here. Rotation comes from
    // a 400 Hz sensor fusion and is good; position comes from a filter coasting between 30 Hz fixes
    // that are already old, and is the shakiest thing in the stack. It no longer reaches the picture.
    //
    // Switching to 3DoF turns it off until 6DoF is back. The "passthrough" launch option (1) starts
    // with it on. While it's on, the eyes move onto the camera (HeadPoseFusion.EyesAtCamera), so the
    // image is seen from where it was taken. It is still one flat picture, and anything else drawn
    // keeps its own depth and fights it, which is seen as doubling, so while passthrough is on the
    // rig's eyes move together (StereoRig.MonoEyes) and the whole view becomes one flat,
    // self-consistent window. In the single phone view the view also takes the AR camera's pose
    // itself, as an ordinary AR app does, which leaves the reprojection nothing to undo: the image
    // then sits still on the screen, at the price of the image's delay, which only matters in a
    // viewer.
    public class PassthroughController : MonoBehaviour
    {
        static readonly int k_DisplayTransformId = Shader.PropertyToID("_UnityDisplayTransform");
        static readonly int k_CaptureFromWorldId = Shader.PropertyToID("_CaptureFromWorld");
        static readonly int k_CaptureFrustumId = Shader.PropertyToID("_CaptureFrustum");
        // The nearest the image comes, in meters.
        const float k_MinDistance = 0.2f;
        // How quickly the image follows a change of focus: most of the way in this many seconds.
        const float k_FocusSeconds = 0.25f;
        // The quad has to reach past every corner of both eye frustums, or the picture would be cut
        // off at the edges of the view. A little over, for a viewer whose lenses are wider than the
        // numbers say, and never under this, which covers the phone view's own 60 degrees.
        const float k_ViewMargin = 1.15f;
        const float k_MinViewExtent = 1.2f;
        // The most the image is magnified to fill the view (the "ptFill" setting).
        public const float k_MaxFill = 2f;

        [SerializeField] HeadPoseFusion m_Fusion;
        [Tooltip("The stereo rig: its eyes move together while passthrough is on, so nothing drawn has " +
                 "a depth the one flat image can't match.")]
        [SerializeField] StereoRig m_Rig;
        [Tooltip("The AR camera. Its ARCameraManager supplies the images and its TrackedPoseDriver places the screen.")]
        [SerializeField] Camera m_ArCamera;
        [Tooltip("A unit quad, a child of the AR camera, that shows the camera image.")]
        [SerializeField] Renderer m_Screen;
        [Tooltip("The panel's toggle, shown selected while passthrough is on.")]
        [SerializeField] M3Button m_Toggle;
        [Tooltip("How far in front of the camera the image is shown without a focus. It's one flat image, so everything in it appears at this depth.")]
        [SerializeField] float m_Distance = 2f;
        [Tooltip("Height of the passthrough texture in pixels; its width follows the camera image's shape.")]
        [SerializeField] int m_TextureHeight = 720;

        ARCameraManager m_CameraManager;
        TrackedPoseDriver m_PoseDriver;
        Material m_CameraMaterial;
        // The quad's own material instance, which carries the reprojection to the shader.
        Material m_ScreenMaterial;
        // The pose the image now in the texture was taken from, in the AR session's own space.
        Matrix4x4 m_CaptureInSession = Matrix4x4.identity;
        Mesh m_Quad;
        CommandBuffer m_Commands;
        RenderTexture m_Texture;
        bool m_On;
        float m_LoggedZoom;
        bool m_LoggedConfigurations;
        // 3DoF turned passthrough off, so it comes back with 6DoF.
        bool m_ResumeWithSixDof;
        // ArDebugView drives the AR camera itself.
        bool m_ArViewActive;
        // The image's frustum at unit distance, in the AR camera's x and y, once an image arrived.
        Vector2 m_FrustumCenter;
        Vector2 m_FrustumSize;
        bool m_HasImage;
        float m_NextTransformLog;
        bool m_Turned;
        float? m_FocusDistance;
        float m_ShownDistance;

        public bool IsOn => m_On;

        // Where the quad should sit, in meters from the eyes, or null for m_Distance. It eases there.
        // The reprojection decides what the quad shows from direction alone, so this no longer
        // changes the picture at all; it is only where the surface sits. PassthroughHandFocus still
        // sets it, and used to warp the picture by doing so.
        public float? FocusDistance
        {
            get => m_FocusDistance;
            set
            {
                if (value.HasValue != m_FocusDistance.HasValue && m_On)
                    Debug.Log(value.HasValue ? $"[Passthrough] Focus at {value.Value:F2} m" : $"[Passthrough] Focus back at {m_Distance:F1} m");
                m_FocusDistance = value;
            }
        }

        void Awake()
        {
            m_CameraManager = m_ArCamera.GetComponent<ARCameraManager>();
            m_PoseDriver = m_ArCamera.GetComponent<TrackedPoseDriver>();
            m_ShownDistance = m_Distance;
            // Instantiated once here rather than through m_Screen.material on each use, which
            // returns the same instance but reads as though it made another.
            m_ScreenMaterial = m_Screen.material;
            // Until the first image, zero size tells the shader there is nothing to show.
            m_ScreenMaterial.SetVector(k_CaptureFrustumId, Vector4.zero);
        }

        // After the other components' OnEnable, so the mode set here sticks.
        void Start()
        {
            m_ArViewActive = LaunchOptions.GetInt("arView", 0) != 0;
            if (LaunchOptions.GetInt("passthrough", 0) != 0)
                SetPassthrough(true);
        }

        void OnDestroy()
        {
            if (m_On)
                m_CameraManager.frameReceived -= OnCameraFrame;
            if (m_Texture != null)
            {
                m_Texture.Release();
                Destroy(m_Texture);
            }
            if (m_CameraMaterial != null)
                Destroy(m_CameraMaterial);
            if (m_Quad != null)
                Destroy(m_Quad);
            m_Commands?.Release();
        }

        public void Toggle() => Choose(!m_On);

        // Turns it on or off as the user's own choice, so 3DoF turning it off doesn't bring it back
        // with 6DoF later.
        public void Choose(bool on)
        {
            m_ResumeWithSixDof = false;
            SetPassthrough(on);
        }

        public void SetPassthrough(bool on)
        {
            if (m_ArViewActive || on == m_On)
                return;

            m_On = on;
            if (on)
            {
                m_Fusion.SetMode(HeadPoseFusion.Mode.SixDof);
                m_CameraManager.frameReceived += OnCameraFrame;
            }
            else
            {
                m_CameraManager.frameReceived -= OnCameraFrame;
            }

            m_PoseDriver.enabled = on;
            m_Fusion.EyesAtCamera = on;
            if (m_Rig != null)
                m_Rig.MonoEyes = on;
            // Shown once the first image has arrived.
            m_Screen.enabled = on && m_HasImage;
            VirtualEnvironment.SetAllHidden(on);
            if (m_Toggle != null)
                m_Toggle.Selected = on;
            Debug.Log(on ? "[Passthrough] On" : "[Passthrough] Off");
        }

        void OnCameraFrame(ARCameraFrameEventArgs args)
        {
            var source = m_CameraManager.cameraMaterial;
            if (source == null || args.textures == null || args.textures.Count == 0 ||
                !args.displayMatrix.HasValue || !args.projectionMatrix.HasValue)
                return;
            // Always the whole camera image, in both views. Mono once cropped it to ARCore's
            // screen-shaped rectangle so it filled the screen, as an ordinary AR app does, but seeing
            // everything the camera saw was better even at the price of a border around it.
            // Where the platform's matrix disagrees with the screen's shape, the matrix is set aside
            // and the whole image mapped directly (below).
            var display = args.displayMatrix.Value;
            var turn = LaunchOptions.GetInt("camTurn", -1);
            var turning = turn < 0 ? NeedsQuarterTurn(display, Screen.width, Screen.height) : turn != 0;
            if (turning != m_Turned)
            {
                m_Turned = turning;
                Debug.Log($"[Passthrough] Camera image turned a quarter: {turning}" +
                          (turn < 0 ? " (decided from the display matrix)" : " (from camTurn)"));
            }

            // The whole camera image, and its true shape. ARCore's matrix is right for the screen,
            // so widening it uncovers the rest of the image (TryWidenDisplayTransform). ARKit's is
            // built for a portrait interface on this landscape screen, and no quarter turn of a
            // crop made for the wrong shape gives a uniform scale: turned one way it stretched the
            // picture 1.75 times taller than wide, and the stretch turned with the head, which is
            // what made tilting the head sickening. So that case drops the crop altogether and
            // maps the screen onto the whole image (WholeImageTransform), with the frustum from the
            // projection's width and the image's own shape (WholeImageFrustum).
            Matrix4x4 widened;
            Vector2 min, max;
            float imageAspect;
            var image = args.textures[0];
            if (turning)
            {
                widened = WholeImageTransform(turn >= 2);
                min = Vector2.zero;
                max = Vector2.one;
                imageAspect = image != null && image.height > 0 ? (float)image.width / image.height : 4f / 3f;
            }
            else
            {
                if (!TryWidenDisplayTransform(display, out widened, out min, out max))
                    return;
                var covered = max - min;
                imageAspect = Screen.width * covered.x / (Screen.height * covered.y);
            }

            if (m_CameraMaterial == null)
            {
                m_CameraMaterial = new Material(source) { name = "Passthrough Camera" };
                EnableRenderPipelineKeyword();
            }
            for (var i = 0; i < args.textures.Count; i++)
                m_CameraMaterial.SetTexture(args.propertyNameIds[i], args.textures[i]);
            m_CameraMaterial.SetMatrix(k_DisplayTransformId, widened);

            var size = max - min;
            EnsureTexture(imageAspect);
            DrawCameraImage();

            // Screen UV maps to NDC as 2uv - 1, which ARCore's projection maps to camera space at unit
            // distance as (ndc + p02) / p00 across and (ndc + p12) / p11 up.
            var projection = args.projectionMatrix.Value;
            if (turning)
            {
                (m_FrustumSize, m_FrustumCenter) = WholeImageFrustum(projection, imageAspect);
            }
            else
            {
                m_FrustumSize = new Vector2(2f * size.x / projection.m00, 2f * size.y / projection.m11);
                m_FrustumCenter = new Vector2(
                    (min.x + max.x - 1f + projection.m02) / projection.m00,
                    (min.y + max.y - 1f + projection.m12) / projection.m11);
            }
            // The pose this image was taken from, which is what the shader reprojects out of. The AR
            // camera's transform carries the pose of the frame being delivered. Kept in the session's
            // own space -- this component sits on the XR Origin, so its transform is where that space
            // is in the world -- because that placing moves: RoomBoundary eases it to line the
            // detected floor up with the virtual one, and recentering turns it bodily. Held as a world
            // pose instead, the picture would lurch whenever the session moved under it, until the
            // next image arrived a thirtieth of a second later.
            m_CaptureInSession = transform.worldToLocalMatrix * m_ArCamera.transform.localToWorldMatrix;
            // The transform is logged again every few seconds, because the one that matters is not
            // the first: a matrix that is wrong at startup and right a second later is a race with
            // the orientation settling, and one that never changes is a standing mismatch. They
            // need different fixes, and the first frame alone cannot tell them apart.
            if (Time.unscaledTime >= m_NextTransformLog && args.displayMatrix.HasValue)
            {
                m_NextTransformLog = Time.unscaledTime + 5f;
                var m = args.displayMatrix.Value;
                // How far the head has turned since this image was taken, which is how much work the
                // reprojection is doing. It is the only thing left that can misplace the picture, and
                // it misplaces it bodily rather than stretching it, so the number is worth having:
                // a degree or two is the lag working as intended, ten says rotational latency itself
                // is what to chase next.
                var turned = Quaternion.Angle(m_ArCamera.transform.rotation, m_Fusion.transform.rotation);
                Debug.Log($"[Passthrough] Display matrix now r0 {m.GetRow(0)} r1 {m.GetRow(1)} r2 {m.GetRow(2)}, " +
                          $"screen {Screen.width}x{Screen.height} {Screen.orientation}, " +
                          $"reprojecting {turned:F1} deg of head turn");
            }

            if (m_HasImage)
                return;

            m_HasImage = true;
            m_Screen.enabled = m_On;
            LogCameraConfigurations();
            Debug.Log($"[Passthrough] Camera image {m_Texture.width}x{m_Texture.height}, " +
                      $"{2f * Mathf.Atan(m_FrustumSize.x / 2f) * Mathf.Rad2Deg:F0} x " +
                      $"{2f * Mathf.Atan(m_FrustumSize.y / 2f) * Mathf.Rad2Deg:F0} deg; " +
                      // AR Foundation builds the display transform from the screen's orientation,
                      // so when the picture comes out turned a quarter, this says whether the
                      // screen had settled into landscape by the time the first frame arrived.
                      $"screen {Screen.width}x{Screen.height} {Screen.orientation}, " +
                      $"autorotate {Screen.autorotateToLandscapeLeft}/{Screen.autorotateToPortrait}");
            LogCameraMaterial(args);
        }

        // ARKit on this phone hands back a display matrix built for a portrait interface even
        // though the screen is landscape and stays that way: measured on an iPhone 18 Pro Max on
        // iOS 27, the matrix was identical over twenty seconds, with screen UV's horizontal axis
        // driving the texture's vertical one and a 0.35 crop -- which is 0.75/2.173, exactly what
        // cropping a turned 4:3 image to a 2868x1320 screen costs. The projection that came with
        // it was right for landscape, so it is the display matrix alone that disagrees.
        //
        // So the screen UV is turned a quarter before the matrix sees it, which puts the texture's
        // long axis back along the screen's long axis; TryWidenDisplayTransform then re-crops as
        // it always did. `camTurn 0` switches it off, for a phone where the matrix is already
        // right, and `camTurn 1` forces it on.
        public static bool NeedsQuarterTurn(Matrix4x4 display, int screenWidth, int screenHeight)
        {
            var landscape = screenWidth > screenHeight;
            // Which way screen-u drives the texture: m00 across, m01 up.
            var uDrivesVertical = Mathf.Abs(display.m01) > Mathf.Abs(display.m00);
            return landscape == uDrivesVertical;
        }

        // Screen UV onto the whole camera image, for a landscape screen whose platform matrix was
        // built for portrait: screen u runs along the image's long axis and screen v down its
        // short one, which is the way up the iPhone 18 Pro Max showed it (measured 2026-11-05;
        // `camTurn 2` flips both for a phone that shows it the other way). The crop the matrix
        // carried is left out on purpose: see OnCameraFrame.
        public static Matrix4x4 WholeImageTransform(bool flipped = false)
        {
            var transform = Matrix4x4.identity;
            if (flipped)
            {
                transform.m00 = -1f; transform.m01 = 0f;
                transform.m10 = 0f;  transform.m11 = 1f;
                transform.m20 = 1f;  transform.m21 = 0f;
            }
            else
            {
                transform.m00 = 1f;  transform.m01 = 0f;
                transform.m10 = 0f;  transform.m11 = -1f;
                transform.m20 = 0f;  transform.m21 = 1f;
            }
            return transform;
        }

        // What the whole image covers, at unit distance, from a projection built for a landscape
        // screen: that screen shows the image's full width, so the projection's width is the
        // image's, and the height follows the image's shape rather than the screen's crop. The
        // center is the projection's principal point.
        public static (Vector2 size, Vector2 center) WholeImageFrustum(Matrix4x4 projection, float imageAspect)
        {
            var width = 2f / projection.m00;
            var size = new Vector2(width, width / Mathf.Max(imageAspect, 1e-3f));
            var center = new Vector2(projection.m02 / projection.m00, projection.m12 / projection.m11);
            return (size, center);
        }

        // How much to magnify the image so it reaches the edges of the view: the view's half-angles
        // over the image's, the larger axis, and no more than k_MaxFill. 1 leaves it at true scale,
        // a window with a border; the magnified picture is uniform, so it stays the right shape as
        // the head turns and tilts, only nearer-looking than life.
        public static float FillZoom(Vector2 imageSize, Vector2 viewHalfTangents, float maxFill = k_MaxFill)
        {
            if (imageSize.x <= 1e-6f || imageSize.y <= 1e-6f)
                return 1f;
            var zoom = Mathf.Max(viewHalfTangents.x / (imageSize.x / 2f), viewHalfTangents.y / (imageSize.y / 2f));
            return Mathf.Clamp(zoom, 1f, maxFill);
        }

        // ARCore's background shader maps screen UV to camera-texture UV as
        // tex = u * (m00, m01) + v * (m10, m11) + (m20, m21), and only screen UV 0 to 1 is drawn: a
        // crop of the camera image shaped like the screen. This finds the screen-UV rectangle the
        // whole texture covers, from min to max, and widens the transform so that screen UV 0 to 1
        // covers all of it.
        public static bool TryWidenDisplayTransform(Matrix4x4 display, out Matrix4x4 widened, out Vector2 min, out Vector2 max)
        {
            widened = display;
            min = max = Vector2.zero;
            var c0 = new Vector2(display.m00, display.m01);
            var c1 = new Vector2(display.m10, display.m11);
            var c2 = new Vector2(display.m20, display.m21);
            var determinant = c0.x * c1.y - c1.x * c0.y;
            if (Mathf.Abs(determinant) < 1e-6f)
                return false;

            Vector2 ScreenUv(Vector2 texture)
            {
                var t = texture - c2;
                return new Vector2((c1.y * t.x - c1.x * t.y) / determinant, (c0.x * t.y - c0.y * t.x) / determinant);
            }

            var a = ScreenUv(new Vector2(0f, 0f));
            var b = ScreenUv(new Vector2(1f, 0f));
            var c = ScreenUv(new Vector2(0f, 1f));
            var d = ScreenUv(new Vector2(1f, 1f));
            min = Vector2.Min(Vector2.Min(a, b), Vector2.Min(c, d));
            max = Vector2.Max(Vector2.Max(a, b), Vector2.Max(c, d));
            var size = max - min;
            widened.m00 = c0.x * size.x;
            widened.m01 = c0.y * size.x;
            widened.m10 = c1.x * size.y;
            widened.m11 = c1.y * size.y;
            var offset = min.x * c0 + min.y * c1 + c2;
            widened.m20 = offset.x;
            widened.m21 = offset.y;
            return true;
        }

        void EnsureTexture(float aspect)
        {
            var height = Mathf.Max(16, m_TextureHeight);
            var width = Mathf.Max(16, Mathf.RoundToInt(height * aspect));
            if (m_Texture != null && m_Texture.width == width && m_Texture.height == height)
                return;
            if (m_Texture != null)
            {
                m_Texture.Release();
                Destroy(m_Texture);
            }
            // With a depth buffer, because both providers' background shaders declare ZWrite On and
            // write SV_Depth. Metal drops the draw when the target has no depth to write to, which
            // left the texture on the clear colour; GLES on Android tolerated it, so this only ever
            // showed up on the iPhone, as a black passthrough image with nothing logged.
            // Clamped, because the shader samples right up to the edge of the image and Repeat would
            // wrap the far edge into that last row of pixels.
            m_Texture = new RenderTexture(width, height, 24) { name = "Passthrough", wrapMode = TextureWrapMode.Clamp };
            m_ScreenMaterial.mainTexture = m_Texture;
        }

        // Reads one pixel back from the middle of the passthrough texture, once. A black quad in the
        // viewer has two quite different causes, and the frame rate and logs look identical for both:
        // either the camera image never reaches this texture, or it does and the screen that shows it
        // is what fails. This says which half of the pipeline to look at.
        Color SampleTextureCentre()
        {
            var previous = RenderTexture.active;
            var probe = new Texture2D(1, 1, TextureFormat.RGBA32, false);
            try
            {
                RenderTexture.active = m_Texture;
                probe.ReadPixels(new Rect(m_Texture.width / 2f, m_Texture.height / 2f, 1f, 1f), 0, 0);
                probe.Apply();
                return probe.GetPixel(0, 0);
            }
            finally
            {
                RenderTexture.active = previous;
                Destroy(probe);
            }
        }

        // ARKit ships one background shader for both render pipelines and chooses between them with a
        // keyword. Without it the shader takes its built-in-pipeline branch, which draws black in a
        // URP project: the image arrives, the draw succeeds, and nothing reports a failure. AR
        // Foundation sets this on its own background renderer feature, which we bypass by drawing the
        // camera image ourselves. ARCore needs nothing here, because it ships a shader per pipeline,
        // so this asks the shader whether it has the keyword rather than assuming a platform.
        void EnableRenderPipelineKeyword()
        {
            if (GraphicsSettings.currentRenderPipeline == null)
                return;

            // Looked up rather than constructed: constructing one the shader lacks, as ARCore's does,
            // logs an error on Android.
            var keyword = m_CameraMaterial.shader.keywordSpace.FindKeyword("ARKIT_BACKGROUND_URP");
            if (keyword.isValid)
                m_CameraMaterial.EnableKeyword(keyword);
        }

        // What the provider actually handed us, logged once. The two platforms differ here more than
        // anywhere else: ARCore gives one RGB texture, ARKit two (luma and chroma) that its own shader
        // converts, and a variant of that shader that didn't survive into the build draws black
        // without failing. Shader, keywords and textures together say which of those is the case.
        void LogCameraMaterial(ARCameraFrameEventArgs args)
        {
            var shader = m_CameraMaterial.shader;
            var keywords = m_CameraMaterial.shaderKeywords;
            var textures = new string[args.textures.Count];
            for (var i = 0; i < args.textures.Count; i++)
            {
                var texture = args.textures[i];
                textures[i] = texture == null
                    ? "null"
                    : $"{texture.width}x{texture.height} {texture.graphicsFormat}";
            }

            Debug.Log($"[Passthrough] Shader {shader.name}, supported {shader.isSupported}, " +
                      $"passes {m_CameraMaterial.passCount}, " +
                      $"keywords {(keywords.Length == 0 ? "none" : string.Join(" ", keywords))}, " +
                      $"{args.textures.Count} textures: {string.Join(", ", textures)}");
            Debug.Log($"[Passthrough] Texture centre reads {SampleTextureCentre()}, " +
                      $"display transform {m_CameraMaterial.GetMatrix(k_DisplayTransformId).GetRow(0)} " +
                      $"{m_CameraMaterial.GetMatrix(k_DisplayTransformId).GetRow(1)}");
            // The one above is this code's widened version, with its offset row left out. When the
            // picture comes out turned a quarter, what matters is what the platform actually
            // handed over, all three rows of it, and the projection it came with.
            if (args.displayMatrix.HasValue)
            {
                var raw = args.displayMatrix.Value;
                Debug.Log($"[Passthrough] Raw display matrix r0 {raw.GetRow(0)} r1 {raw.GetRow(1)} r2 {raw.GetRow(2)}");
            }
            if (args.projectionMatrix.HasValue)
            {
                var p = args.projectionMatrix.Value;
                Debug.Log($"[Passthrough] Projection m00 {p.m00:F4} m11 {p.m11:F4} m02 {p.m02:F4} m12 {p.m12:F4}" +
                          $" (m00<m11 means a taller-than-wide frustum, which on a landscape screen is the turn)");
            }
        }

        // Draws the camera image into the texture the way ARCameraBackground draws the screen: a unit
        // quad through an orthographic projection.
        void DrawCameraImage()
        {
            if (m_Quad == null)
                m_Quad = CreateUnitQuad();
            m_Commands ??= new CommandBuffer { name = "Passthrough Camera Image" };
            m_Commands.Clear();
            m_Commands.SetRenderTarget(m_Texture);
            m_Commands.ClearRenderTarget(false, true, Color.black);
            m_Commands.SetViewProjectionMatrices(Matrix4x4.identity, Matrix4x4.Ortho(0f, 1f, 0f, 1f, -0.1f, 9.9f));
            m_Commands.DrawMesh(m_Quad, Matrix4x4.identity, m_CameraMaterial);
            Graphics.ExecuteCommandBuffer(m_Commands);
        }

        static Mesh CreateUnitQuad()
        {
            var mesh = new Mesh { name = "Passthrough Quad" };
            mesh.SetVertices(new[]
            {
                new Vector3(0f, 0f, 0.1f), new Vector3(0f, 1f, 0.1f), new Vector3(1f, 1f, 0.1f), new Vector3(1f, 0f, 0.1f),
            });
            mesh.SetUVs(0, new[] { new Vector2(0f, 0f), new Vector2(0f, 1f), new Vector2(1f, 1f), new Vector2(1f, 0f) });
            mesh.SetTriangles(new[] { 0, 1, 2, 0, 2, 3 }, 0);
            return mesh;
        }

        void LateUpdate()
        {
            // In the single phone view the view takes the camera's own pose, the one the image was taken
            // from, so the image sits still on the screen instead of shaking between the fused head
            // pose and each frame's (HeadPoseFusion.FollowPose). In the viewer it stays fused.
            var follow = m_On && m_Rig != null && m_Rig.IsMono ? m_ArCamera.transform : null;
            if (m_Fusion.FollowPose != follow)
            {
                m_Fusion.FollowPose = follow;
                Debug.Log(follow != null ? "[Passthrough] Phone view: the view follows the camera's pose" :
                    "[Passthrough] The view follows the fused head pose");
            }
            var sixDof = m_Fusion.CurrentMode == HeadPoseFusion.Mode.SixDof;
            if (!m_On)
            {
                if (m_ResumeWithSixDof && sixDof)
                {
                    m_ResumeWithSixDof = false;
                    SetPassthrough(true);
                }
                return;
            }
            // Switching to 3DoF turns ARCore, and so the camera, off.
            if (!sixDof)
            {
                SetPassthrough(false);
                m_ResumeWithSixDof = true;
                return;
            }
            if (!m_HasImage)
                return;

            // Eased in proportion, so moving from 2 m to 0.3 m takes as long as 0.3 m to 0.045 m would.
            var target = Mathf.Clamp(m_FocusDistance ?? m_Distance, k_MinDistance, m_Distance);
            var step = 1f - Mathf.Exp(-Time.unscaledDeltaTime / k_FocusSeconds);
            m_ShownDistance = Mathf.Exp(Mathf.Lerp(Mathf.Log(m_ShownDistance), Mathf.Log(target), step));
            // After RoomBoundary's Update, which places the session in the world this frame.
            m_ScreenMaterial.SetMatrix(k_CaptureFromWorldId,
                (transform.localToWorldMatrix * m_CaptureInSession).inverse);
            // Fill the view (the setting, on by default) by magnifying the image uniformly, or show
            // it at true scale as a window.
            var zoom = Settings.Int("ptFill", 1) != 0 ? FillZoom(m_FrustumSize, ViewHalfTangents()) : 1f;
            if (!Mathf.Approximately(zoom, m_LoggedZoom))
            {
                m_LoggedZoom = zoom;
                Debug.Log($"[Passthrough] Image {2f * Mathf.Atan(m_FrustumSize.x / 2f) * Mathf.Rad2Deg:F0} x " +
                          $"{2f * Mathf.Atan(m_FrustumSize.y / 2f) * Mathf.Rad2Deg:F0} deg shown " +
                          (zoom > 1f ? $"magnified {zoom:F2}x to fill the view" : "at true scale, as a window"));
            }
            m_ScreenMaterial.SetVector(k_CaptureFrustumId,
                new Vector4(m_FrustumCenter.x, m_FrustumCenter.y, m_FrustumSize.x / zoom, m_FrustumSize.y / zoom));

            var d = m_ShownDistance;
            // Square to the view and centered on it, rather than on the camera's frustum: the shader
            // decides what each pixel shows from the direction it looks in, so this only has to be
            // the surface those pixels are drawn on, and has to reach the edges of the view.
            var screen = m_Screen.transform;
            screen.SetLocalPositionAndRotation(new Vector3(0f, 0f, d), Quaternion.identity);
            var across = 2f * d * ViewExtent();
            screen.localScale = new Vector3(across, across, 1f);
        }

        // The tangents of the widest half-angles either eye sees, across and up.
        Vector2 ViewHalfTangents()
        {
            var tangents = new Vector2(k_MinViewExtent, k_MinViewExtent);
            var lens = m_Rig != null ? m_Rig.Lens : null;
            if (lens != null)
            {
                foreach (var eye in new[] { Eye.Left, Eye.Right })
                {
                    // Left, right, bottom and top half-angles, in radians.
                    var fov = lens.GetFieldOfView(eye);
                    tangents.x = Mathf.Max(tangents.x, Mathf.Max(Mathf.Tan(fov.x), Mathf.Tan(fov.y)));
                    tangents.y = Mathf.Max(tangents.y, Mathf.Max(Mathf.Tan(fov.z), Mathf.Tan(fov.w)));
                }
            }
            return tangents;
        }

        // The half-extent of the square quad, as a tangent: the view's own corner, so that the
        // corners are in whichever way the head is tilted. A square the width of the view alone
        // left its corners bare the moment the head rolled.
        float ViewExtent() => ViewHalfTangents().magnitude * k_ViewMargin;

        // The camera configurations ARKit or ARCore offer, logged once, and the "camConfig N"
        // launch option to pick one: a wider format, if a phone has one, would fill the view at true
        // scale instead of by magnifying. AR Foundation shows only size and rate, so which is which
        // is a thing to read off the phone.
        void LogCameraConfigurations()
        {
            if (m_CameraManager == null || m_LoggedConfigurations)
                return;
            m_LoggedConfigurations = true;
            try
            {
                using var configurations = m_CameraManager.GetConfigurations(Unity.Collections.Allocator.Temp);
                var current = m_CameraManager.currentConfiguration;
                var lines = new System.Text.StringBuilder();
                for (var i = 0; i < configurations.Length; i++)
                {
                    var c = configurations[i];
                    var isCurrent = current.HasValue && current.Value.Equals(c);
                    lines.Append(i == 0 ? "" : ", ").Append(i).Append(": ").Append(c.width).Append('x').Append(c.height)
                        .Append('@').Append(c.framerate ?? 0).Append(isCurrent ? " (current)" : "");
                }
                Debug.Log($"[Passthrough] Camera configurations: {(configurations.Length == 0 ? "none listed" : lines.ToString())}");
                var wanted = LaunchOptions.GetInt("camConfig", -1);
                if (wanted >= 0 && wanted < configurations.Length)
                {
                    m_CameraManager.currentConfiguration = configurations[wanted];
                    Debug.Log($"[Passthrough] Camera configuration {wanted} asked for");
                }
            }
            catch (System.Exception e)
            {
                Debug.Log($"[Passthrough] Camera configurations couldn't be read: {e.Message}");
            }
        }

        // Where a point the eye is looking at falls in the passthrough texture, from 0 to 1 on each
        // axis. False when there is no image yet, or when the point lies behind the camera that took
        // the one there is; InImage then says whether it was in the picture at all.
        //
        // The shader does exactly this, per pixel, on the world position of the fragment and this
        // eye's own position. It is here as well so the mapping can be tested, because the two
        // properties the fix rests on are statements about this function: every point along one line
        // of sight lands on the same pixel, and sliding the eye along that line of sight -- which is
        // all a wrong position estimate does to it -- cannot move the picture.
        public static bool TryImageUv(Matrix4x4 captureFromWorld, Vector3 eyePosition, Vector3 worldPoint,
                                      Vector2 center, Vector2 size, out Vector2 uv)
        {
            uv = Vector2.zero;
            if (size.x <= 1e-6f || size.y <= 1e-6f)
                return false;
            // A direction, so only the rotation in captureFromWorld bears on it.
            var inCamera = captureFromWorld.MultiplyVector(worldPoint - eyePosition);
            if (inCamera.z <= 1e-6f)
                return false;
            uv = new Vector2(
                (inCamera.x / inCamera.z - center.x) / size.x + 0.5f,
                (inCamera.y / inCamera.z - center.y) / size.y + 0.5f);
            return true;
        }

        public static bool InImage(Vector2 uv) =>
            uv.x >= 0f && uv.x <= 1f && uv.y >= 0f && uv.y <= 1f;
    }
}
