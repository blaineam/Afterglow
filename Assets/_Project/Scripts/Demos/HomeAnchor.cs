using Afterglow.Hands;
using Afterglow.Stereo;
using Afterglow.UI;
using UnityEngine;

namespace Afterglow.Demos
{
    // The way home from anywhere: a round Home button that floats low in the view, below whatever
    // an app shows, following the head's heading lazily. Look down at it and tap or pinch and the
    // settings panel opens with the home screen, from a game, the player or the browser alike.
    // The palm gear does the same but needs a hand in the camera's view, and the corner gear
    // needs the phone in hand; this needs neither, which is what a viewer wants. Hidden while
    // the panel is open, since the panel is then the way everywhere. Lives in Core. Logs [Home].
    public class HomeAnchor : MonoBehaviour
    {
        // Low enough to clear an app's own panels (the player's controls sit about 20 degrees
        // below the gaze, the browser's bar lower), near enough to read.
        const float k_Pitch = -52f;
        const float k_Distance = 1.1f;
        const float k_DeadZone = 30f;

        [SerializeField] HeadPoseFusion m_Fusion;
        [SerializeField] HomeScreen m_Home;

        RectTransform m_Canvas;
        float m_Yaw;
        bool m_Following;
        float m_YawSpeed;

        void Start()
        {
            m_Canvas = M3.Canvas("Home Anchor", transform, new Vector2(56f, 56f), k_Distance);
            m_Canvas.gameObject.AddComponent<Interaction.GazeCanvas>();
            M3.IconButton("Home", m_Canvas, "home", M3Button.Variant.Filled, Vector2.zero, GoHome, 56f);
            m_Yaw = HeadYaw();
        }

        void GoHome()
        {
            Debug.Log("[Home] The anchor was pressed");
            if (m_Home != null)
                m_Home.Open();
        }

        void LateUpdate()
        {
            if (m_Canvas == null || m_Fusion == null)
                return;
            var shown = !SettingsSummoner.IsPanelOpen;
            if (m_Canvas.gameObject.activeSelf != shown)
                m_Canvas.gameObject.SetActive(shown);
            if (!shown)
                return;
            m_Yaw = SettingsSummoner.FollowYaw(m_Yaw, HeadYaw(), k_DeadZone, ref m_Following, ref m_YawSpeed, Time.unscaledDeltaTime);
            var head = m_Fusion.transform.position;
            var direction = Quaternion.Euler(-k_Pitch, m_Yaw, 0f) * Vector3.forward;
            var position = head + direction * k_Distance;
            m_Canvas.SetPositionAndRotation(position, Quaternion.LookRotation(direction, Vector3.up));
        }

        float HeadYaw()
        {
            var flat = Vector3.ProjectOnPlane(m_Fusion.transform.forward, Vector3.up);
            return flat.sqrMagnitude > 1e-4f ? Quaternion.LookRotation(flat.normalized).eulerAngles.y : m_Yaw;
        }
    }
}
