using UnityEngine;
using UnityEngine.InputSystem;

namespace CardboardXR.Stereo
{
    // Head tracking for a desk, where there is no phone to turn: the Editor without XR Simulation,
    // and the iOS Simulator. It takes over only while GyroHeadTracker found no sensors, so on a
    // phone it does nothing at all, and only in 3DoF, where the tracker would have owned the
    // transform; in 6DoF HeadPoseFusion does.
    //
    // Look with a right-button drag (a mouse) or any drag (a touch screen, which is what the
    // Simulator's mouse is). The left button stays a tap, so clicking still clicks; GazePointer
    // treats a drag as not-a-tap, so a look does not also press whatever the gaze crosses. Move with
    // W A S D or the arrows, Q and E for down and up, and R to face forward again. The point is to
    // run the app's screens, media and browser without a phone, not to stand in for ARKit.
    [DefaultExecutionOrder(-99)]
    public class DeskHeadLook : MonoBehaviour
    {
        const float k_DegreesPerPixel = 0.15f;
        const float k_MetersPerSecond = 1.2f;
        const float k_MaxPitch = 85f;

        [SerializeField] GyroHeadTracker m_Tracker;

        float m_Yaw;
        float m_Pitch;
        bool m_Announced;
        // Where the drag was last frame, so the look is the pointer's own movement. Not the Input
        // System's delta: a touch's delta on iOS came through lumpy enough in the Simulator to turn
        // a drag-and-return into a large net turn.
        bool m_Dragging;
        Vector2 m_LastPointer;
        Vector2 m_DragStart;

        // Whether this is what moves the head right now.
        public bool IsActive => (m_Tracker == null || !m_Tracker.HasSensors) && (m_Tracker == null || m_Tracker.DrivesTransform);

        void Awake()
        {
            if (m_Tracker == null)
                m_Tracker = GetComponent<GyroHeadTracker>();
        }

        void Update()
        {
            if (!IsActive)
                return;
            if (!m_Announced)
            {
                m_Announced = true;
                Debug.Log("[Stereo] Desk mode: no motion sensors, so drag to look (right button on a mouse), " +
                          "W A S D / arrows to move, Q E down and up, R to face forward");
            }

            var delta = Vector2.zero;
            var pressed = false;
            var pointer = Vector2.zero;
            var mouse = Mouse.current;
            if (mouse != null && mouse.rightButton.isPressed)
            {
                pressed = true;
                pointer = mouse.position.ReadValue();
            }
            else
            {
                var touch = Touchscreen.current;
                if (touch != null && touch.primaryTouch.press.isPressed)
                {
                    pressed = true;
                    pointer = touch.primaryTouch.position.ReadValue();
                }
            }
            if (pressed && m_Dragging)
                delta = pointer - m_LastPointer;
            if (pressed && !m_Dragging)
                m_DragStart = pointer;
            // One line per drag, on release: enough to see what the screen delivered and what it
            // turned into, without a line per frame.
            if (!pressed && m_Dragging)
                Debug.Log($"[Stereo] Desk drag {m_LastPointer - m_DragStart} px of {Screen.width}x{Screen.height}; " +
                          $"now yaw {m_Yaw:F1} pitch {m_Pitch:F1}; mouse {(Mouse.current != null ? "yes" : "no")}, " +
                          $"touch {(Touchscreen.current != null ? "yes" : "no")}");
            m_Dragging = pressed;
            m_LastPointer = pointer;
            m_Yaw += delta.x * k_DegreesPerPixel;
            m_Pitch = Mathf.Clamp(m_Pitch - delta.y * k_DegreesPerPixel, -k_MaxPitch, k_MaxPitch);

            var move = Vector3.zero;
            var keyboard = Keyboard.current;
            if (keyboard != null)
            {
                if (keyboard.wKey.isPressed || keyboard.upArrowKey.isPressed) move.z += 1f;
                if (keyboard.sKey.isPressed || keyboard.downArrowKey.isPressed) move.z -= 1f;
                if (keyboard.dKey.isPressed || keyboard.rightArrowKey.isPressed) move.x += 1f;
                if (keyboard.aKey.isPressed || keyboard.leftArrowKey.isPressed) move.x -= 1f;
                if (keyboard.eKey.isPressed) move.y += 1f;
                if (keyboard.qKey.isPressed) move.y -= 1f;
                if (keyboard.rKey.wasPressedThisFrame)
                {
                    m_Yaw = 0f;
                    m_Pitch = 0f;
                    transform.localPosition = Vector3.zero;
                }
            }

            var rotation = Quaternion.Euler(m_Pitch, m_Yaw, 0f);
            transform.localRotation = rotation;
            if (move != Vector3.zero)
            {
                // Along the floor the way the head faces, so looking up doesn't walk you into the air.
                var heading = Quaternion.Euler(0f, m_Yaw, 0f);
                transform.localPosition += heading * move.normalized * (k_MetersPerSecond * Time.unscaledDeltaTime);
            }
        }
    }
}
