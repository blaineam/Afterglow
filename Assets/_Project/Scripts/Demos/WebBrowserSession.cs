using System.IO;
using CardboardXR.Hands;
using CardboardXR.Interaction;
using CardboardXR.Stereo;
using CardboardXR.UI;
using UnityEngine.UI;
using UnityEngine;

namespace CardboardXR.Demos
{
    // Runs the in-app browser: a page hung on a quad in the scene, fed the head pose, driven by
    // gaze and pinch, and handed the whole screen only when a page starts an immersive session.
    //
    // It lives here rather than beside WebBrowser in Core because pinches come from the hands
    // assembly, and this is the layer that can see both.
    //
    // Why a window rather than the whole screen: a web view's pixels cannot be had at headset
    // frame rates through any public API, so an immersive WebXR session has to be the real view,
    // over everything. But a page being read is not moving, and a snapshot a dozen times a second
    // is plenty for it -- so ordinary browsing can be a surface in the room with the passthrough
    // still behind it, which is what looking at a page in a headset should feel like.
    public class WebBrowserSession : MonoBehaviour, IPinchHandler
    {
        [Tooltip("The page the browser opens on, inside StreamingAssets.")]
        [SerializeField] string m_HomePage = "webxr/index.html";
        [SerializeField] StereoRig m_Rig;
        [SerializeField] HeadPoseFusion m_Fusion;
        [Tooltip("Meters. How far ahead the window hangs, and how wide it is there.")]
        [SerializeField] float m_Distance = 1.6f;
        [SerializeField] float m_Width = 1.25f;
        [Tooltip("Looking within this fraction of the window's top or bottom scrolls the page.")]
        [SerializeField, Range(0.02f, 0.3f)] float m_ScrollEdge = 0.12f;
        [SerializeField] float m_ScrollSpeed = 900f;
        [Tooltip("The capture and the quad disagree about which way is up; this is which one wins.")]
        [SerializeField] bool m_FlipV = true;

        IPinchHandler m_Interrupted;
        GameObject m_Window;
        RectTransform m_Bar;
        static readonly float[] k_Widths = { 0.8f, 1.25f, 1.9f, 2.8f };
        int m_WidthStep = 1;
        MeshRenderer m_Renderer;
        Material m_Material;
        Texture2D m_Page;
        bool m_Immersive;

        public bool IsOpen => WebBrowser.IsOpen;

        public void Toggle()
        {
            if (WebBrowser.IsOpen)
                Close();
            else
                Open();
        }

        public void Open()
        {
            if (!WebBrowser.Supported)
            {
                Debug.Log("[WebXR] The browser is iOS only; nothing to open here.");
                return;
            }
            var page = Path.Combine(Application.streamingAssetsPath, m_HomePage);
            if (!WebBrowser.Open("file://" + page, m_Rig, m_Fusion != null && m_Fusion.IsArTracking))
                return;

            BuildWindow();
            m_Immersive = false;
            // PinchRouter asks the scene's handler only while the settings panel is shut, and the
            // browser is opened from that panel -- so leaving it up means every pinch goes to its
            // buttons and the page never gets one.
            var settings = CoreServices.Instance != null ? CoreServices.Instance.Settings : null;
            if (settings != null && settings.IsOpen)
                settings.Close();
            // The window is what the pinches are for, until a page takes the screen.
            m_Interrupted = PinchRouter.Handler;
            PinchRouter.Handler = this;
        }

        public void Close()
        {
            if (!WebBrowser.IsOpen)
                return;
            WebBrowser.Close();
            if (ReferenceEquals(PinchRouter.Handler, this))
                PinchRouter.Handler = m_Interrupted;
            m_Interrupted = null;
            TearDownWindow();
        }

        void OnDisable() => Close();

        // A quad ahead of the user, in the page's own 4:3, with a collider so the gaze can say
        // where on the page it landed.
        void BuildWindow()
        {
            if (m_Window != null)
                return;
            var height = m_Width * WebBrowser.WindowHeight / WebBrowser.WindowWidth;
            m_Window = GameObject.CreatePrimitive(PrimitiveType.Quad);
            m_Window.name = "Web Window";
            m_Window.transform.SetParent(transform, false);
            m_Window.transform.localScale = new Vector3(m_Width, height, 1f);
            m_Renderer = m_Window.GetComponent<MeshRenderer>();
            m_Renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            m_Renderer.receiveShadows = false;
            var shader = Shader.Find("Universal Render Pipeline/Unlit");
            m_Material = new Material(shader) { name = "Web Page" };
            // The capture's rows and the quad's UV disagree about which way is up, so the page
            // arrived upside down. Flipping V here keeps the fix in one place: TryGazePoint flips
            // with it, so where you look and what you click stay the same point.
            if (m_FlipV)
            {
                m_Material.mainTextureScale = new Vector2(1f, -1f);
                m_Material.mainTextureOffset = new Vector2(0f, 1f);
            }
            m_Renderer.sharedMaterial = m_Material;
            m_Width = k_Widths[m_WidthStep];
            ApplySize();
            BuildControls();
            Place();
        }

        void GoHome()
        {
            Close();
            Open();
        }

        void TearDownWindow()
        {
            if (m_Bar != null)
                Destroy(m_Bar.gameObject);
            m_Bar = null;
            if (m_Window != null)
                Destroy(m_Window);
            if (m_Material != null)
                Destroy(m_Material);
            if (m_Page != null)
                Destroy(m_Page);
            m_Window = null;
            m_Material = null;
            m_Page = null;
        }

        // Straight ahead of where the head is looking, upright, at arm's length and a bit.
        void Place()
        {
            if (m_Window == null || m_Fusion == null)
                return;
            var head = m_Fusion.transform;
            var forward = head.forward;
            forward.y = 0f;
            if (forward.sqrMagnitude < 1e-4f)
                forward = Vector3.forward;
            forward.Normalize();
            m_Window.transform.position = head.position + forward * m_Distance;
            m_Window.transform.rotation = Quaternion.LookRotation(forward, Vector3.up);
            if (m_Bar != null)
            {
                // Just under the window, facing the same way, far enough down to clear the page's
                // bottom edge at whatever size it is now.
                var height = m_Width * WebBrowser.WindowHeight / WebBrowser.WindowWidth;
                m_Bar.position = m_Window.transform.position - m_Window.transform.up * (height / 2f + 0.09f);
                m_Bar.rotation = m_Window.transform.rotation;
            }
        }

        void Update()
        {
            if (!WebBrowser.IsOpen)
                return;

            if (m_Fusion != null)
            {
                var head = m_Fusion.transform;
                WebBrowser.PushPose(head.position, head.rotation);
            }

            switch (WebBrowser.TakeEvent())
            {
                case WebBrowser.Event.SessionStart:
                    // Only this needs the frame rate, so only this takes the screen.
                    m_Immersive = true;
                    WebBrowser.SetWindowed(false);
                    if (m_Window != null)
                        m_Window.SetActive(false);
                    if (m_Bar != null)
                        m_Bar.gameObject.SetActive(false);
                    Debug.Log("[WebXR] Immersive session: the page has the screen");
                    break;
                case WebBrowser.Event.SessionEnd:
                    m_Immersive = false;
                    WebBrowser.SetWindowed(true);
                    if (m_Window != null)
                        m_Window.SetActive(true);
                    if (m_Bar != null)
                        m_Bar.gameObject.SetActive(true);
                    Place();
                    Debug.Log("[WebXR] Session ended: back to a window in the scene");
                    break;
                case WebBrowser.Event.Close:
                    Close();
                    return;
            }

            if (m_Immersive)
                return;

            if (WebBrowser.TryUpdateTexture(ref m_Page) && m_Material != null)
                m_Material.mainTexture = m_Page;

            GazeScroll();
        }

        // Looking near the window's top or bottom edge scrolls the page, so reading needs no
        // hands at all -- which matters in a viewer, where a pinch is the only other input and
        // holding one to scroll is tiring.
        void GazeScroll()
        {
            if (!TryGazePoint(out _, out var v))
                return;
            var from = v < m_ScrollEdge ? (v - m_ScrollEdge) / m_ScrollEdge
                     : v > 1f - m_ScrollEdge ? (v - (1f - m_ScrollEdge)) / m_ScrollEdge
                     : 0f;
            if (Mathf.Approximately(from, 0f))
                return;
            // v is measured down the page, so looking low scrolls down.
            WebBrowser.ScrollBy(0f, from * m_ScrollSpeed * Time.unscaledDeltaTime);
        }

        // Where the head's gaze meets the window, as 0-1 across and down the page.
        bool TryGazePoint(out float u, out float v)
        {
            u = v = 0f;
            if (m_Window == null || m_Fusion == null || !m_Window.activeSelf)
                return false;
            var head = m_Fusion.transform;
            if (!Physics.Raycast(head.position, head.forward, out var hit, m_Distance * 4f))
                return false;
            if (hit.collider.gameObject != m_Window)
                return false;
            var local = m_Window.transform.InverseTransformPoint(hit.point);
            u = local.x + 0.5f;
            // Unity's quad has y up and a page counts down from the top; m_FlipV is the same
            // correction the material gets, so the two always agree.
            v = m_FlipV ? local.y + 0.5f : 0.5f - local.y;
            return u >= 0f && u <= 1f && v >= 0f && v <= 1f;
        }

        // A pinch clicks wherever the gaze is on the page.
        public bool TryBeginPinch(GameObject gazeTarget, PinchSource source)
        {
            if (!WebBrowser.IsOpen || m_Immersive)
                return false;
            if (!TryGazePoint(out var u, out var v))
                return false;

            WebBrowser.ClickAt(u, v);
            Debug.Log($"[WebXR] Click at {u:F2}, {v:F2} on the page");
            return true;
        }

        // Through the sizes rather than by a factor, so the button lands somewhere sensible every
        // time instead of drifting.
        void CycleSize()
        {
            m_WidthStep = (m_WidthStep + 1) % k_Widths.Length;
            m_Width = k_Widths[m_WidthStep];
            ApplySize();
            Place();
            Debug.Log($"[WebXR] Window {m_Width:F2} m wide");
        }

        void ApplySize()
        {
            if (m_Window == null)
                return;
            var height = m_Width * WebBrowser.WindowHeight / WebBrowser.WindowWidth;
            m_Window.transform.localScale = new Vector3(m_Width, height, 1f);
        }

        // The controls, as the app's own toolbar rather than invented gestures: real buttons the
        // gaze lights up and a pinch presses, which PinchRouter already handles before it ever
        // reaches this demo. It hangs under the window and moves with it.
        void BuildControls()
        {
            if (m_Bar != null)
                return;
            const float width = 92f, padding = 12f;
            var labels = new (string icon, string label, UnityEngine.Events.UnityAction action)[]
            {
                ("chevron_left", "Back", WebBrowser.GoBack),
                ("home", "Home", GoHome),
                ("refresh", "Reload", () => WebBrowser.ScrollBy(0f, 0f)),
                ("aspect_ratio", "Size", CycleSize),
                ("open_with", "Place", Place),
                ("close", "Close", Close),
            };
            m_Bar = M3.Canvas("Web Controls", transform,
                new Vector2(labels.Length * width + 2f * padding, 76f + 2f * padding),
                M3Theme.k_OverlayDistance, M3Theme.SurfaceContainerHigh, M3Theme.k_ShapeFull);
            m_Bar.gameObject.AddComponent<GazeCanvas>();

            var items = new RectTransform[labels.Length];
            var groups = new int[labels.Length];
            for (var i = 0; i < labels.Length; i++)
            {
                var (icon, label, action) = labels[i];
                items[i] = (RectTransform)M3.ToolbarItem(label, m_Bar, icon, label, Vector2.zero, width, action).transform;
                groups[i] = i < 3 ? 0 : 1;
            }
            m_Bar.gameObject.AddComponent<M3Toolbar>()
                .Initialize(items, groups, new Image[2], new RectTransform[0], width, padding, 0f);
        }

        public void EndPinch() { }
    }
}
