using System.IO;
using CardboardXR.Hands;
using CardboardXR.Stereo;
using UnityEngine;

namespace CardboardXR.Demos
{
    // Runs the in-app browser: opens it, feeds it the head pose, turns pinches into WebXR selects,
    // and closes it when the page asks.
    //
    // It lives here rather than beside WebBrowser in Core because pinches come from the hands
    // assembly, and this is the layer that can see both. While the browser is in front it takes
    // every pinch, since nothing of Unity's is visible to aim at.
    public class WebBrowserSession : MonoBehaviour, IPinchHandler
    {
        [Tooltip("The page the browser opens on, inside StreamingAssets.")]
        [SerializeField] string m_HomePage = "webxr/index.html";
        [SerializeField] StereoRig m_Rig;
        [SerializeField] HeadPoseFusion m_Fusion;

        IPinchHandler m_Interrupted;

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

            // The page is over everything, so it takes the pinches until it closes.
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
        }

        void OnDisable() => Close();

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
                    Debug.Log("[WebXR] The page started an immersive session");
                    break;
                case WebBrowser.Event.SessionEnd:
                    Debug.Log("[WebXR] The page ended its session");
                    break;
                case WebBrowser.Event.Close:
                    Close();
                    break;
            }
        }

        // Every pinch, while the browser is up, is a select in the page.
        public bool TryBeginPinch(GameObject gazeTarget, PinchSource source)
        {
            if (!WebBrowser.IsOpen)
                return false;
            WebBrowser.Select();
            return true;
        }

        public void EndPinch() { }
    }
}
