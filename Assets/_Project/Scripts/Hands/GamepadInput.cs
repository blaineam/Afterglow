using Afterglow.Interaction;
using Afterglow.Stereo;
using UnityEngine;
using UnityEngine.InputSystem;

namespace Afterglow.Hands
{
    // A Bluetooth controller, as another way to press what the gaze is on.
    //
    // Hand tracking is the app's own input and it is good, but it asks a lot: the camera sees
    // about 68 degrees across, so a hand has to be held up in front of the chest, and it leaves
    // the frame often. A controller costs nothing to hold, works in the dark, and never leaves the
    // frame -- and it is the only input that will carry a seated game later.
    //
    // The button goes through PinchRouter as a pinch rather than clicking anything itself, so it
    // inherits the whole order already settled there: the settings gear first, then a button under
    // the gaze, then the scene's own use of it, then a plain click. Nothing has to know a
    // controller exists.
    public class GamepadInput : MonoBehaviour
    {
        [SerializeField] GazePointer m_Gaze;
        [SerializeField] HeadPoseFusion m_Fusion;
        [Tooltip("How fast the stick scrolls, in page pixels a second.")]
        [SerializeField] float m_ScrollSpeed = 1400f;
        [Tooltip("Below this the stick is treated as centred.")]
        [SerializeField, Range(0.05f, 0.5f)] float m_Deadzone = 0.2f;

        bool m_Pressed;
        string m_Known;

        // What the stick is asking to scroll, for whatever is showing a page. Zero when no
        // controller is connected, so a caller needs no test of its own.
        public static Vector2 Scroll { get; private set; }

        void Update()
        {
            var pad = Gamepad.current;
            if (pad == null)
            {
                if (m_Known != null)
                {
                    Debug.Log($"[Pinch] Controller {m_Known} gone");
                    m_Known = null;
                    Release();
                }
                Scroll = Vector2.zero;
                return;
            }

            if (m_Known != pad.name)
            {
                m_Known = pad.name;
                Debug.Log($"[Pinch] Controller {pad.name} connected");
            }

            // South (A / Cross) is the press; the trigger does the same, since which one falls
            // under the finger depends on the controller.
            var down = pad.buttonSouth.isPressed || pad.rightTrigger.isPressed;
            if (down && !m_Pressed)
            {
                m_Pressed = true;
                var route = PinchRouter.Begin(PinchSource.Camera, m_Gaze, false);
                Debug.Log($"[Pinch] Controller press went to {route}");
            }
            else if (!down && m_Pressed)
            {
                Release();
            }

            // East (B / Circle) recentres, which is the thing most worth reaching without hands.
            if (pad.buttonEast.wasPressedThisFrame && m_Fusion != null)
            {
                m_Fusion.Recenter();
                Debug.Log("[Pinch] Controller recentred");
            }

            // Start opens the settings panel, so a controller alone can reach everything.
            if (pad.startButton.wasPressedThisFrame)
                SettingsPanelHub.Open();

            var stick = pad.rightStick.ReadValue();
            if (stick.sqrMagnitude < m_Deadzone * m_Deadzone)
                stick = pad.leftStick.ReadValue();
            Scroll = stick.sqrMagnitude < m_Deadzone * m_Deadzone
                ? Vector2.zero
                : stick * m_ScrollSpeed;
        }

        void Release()
        {
            if (!m_Pressed)
                return;
            m_Pressed = false;
            PinchRouter.End();
        }

        void OnDisable() => Release();
    }
}
