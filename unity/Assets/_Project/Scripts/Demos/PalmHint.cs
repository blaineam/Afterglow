using Afterglow.UI;
using UnityEngine;

namespace Afterglow.Demos
{
    // One line of guidance, low in front of where the user starts a scene: how to bring back the
    // settings panel and the home screen, which open by themselves on entering the Home scene
    // (HomeScreen) but can be closed. The Home scene and the Room are otherwise just places to
    // start from.
    public class PalmHint : MonoBehaviour
    {
        [Tooltip("How far the hint is from the user, in meters.")]
        [SerializeField] float m_Distance = M3Theme.k_PanelDistance;
        [Tooltip("Where it is, in degrees above (+) or below (-) eye level.")]
        [SerializeField] float m_Pitch = -21f;
        [SerializeField] string m_Text = "Look at your palm, then pinch, for Home and settings";

        void Start()
        {
            var hint = M3.Canvas("Palm Hint", transform, new Vector2(560f, 32f), m_Distance);
            var direction = Quaternion.Euler(-m_Pitch, 0f, 0f) * Vector3.forward;
            hint.SetPositionAndRotation(direction * m_Distance, Quaternion.LookRotation(direction, Vector3.up));
            M3.Icon("Icon", hint, "home", 20f, new Vector2(-230f, 0f), M3Theme.OnSurfaceVariant);
            M3.Text("Text", hint, m_Text, M3Theme.Type.BodyLarge, new Vector2(16f, 0f),
                new Vector2(460f, 32f), M3Theme.OnSurfaceVariant);
        }
    }
}
