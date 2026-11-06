using System.Collections;
using CardboardXR.Hands;
using CardboardXR.Stereo;
using CardboardXR.UI;
using TMPro;
using UnityEngine;

namespace CardboardXR.Demos
{
    // The room scan's panel, shown over an app that scans the room as it opens (DemoManager, for a
    // catalog entry with ScanSurfaces, in 6DoF, when the room hasn't been scanned since 6DoF began):
    // it asks the user to look around at the floor and any tables while the surfaces appear in the
    // scan's wave, and counts what's been found. The scan ends by itself once nothing new turns up
    // (RoomBoundary.ScanRoom), or with Done or Skip; it waits for tracking to start however long
    // that takes (the phone may still be face down), and gives up only if 6DoF itself ends. The app
    // runs meanwhile, so nothing waits on the scan; the panel goes when the scan does, or when
    // another scene loads. Hand tracking pauses for the scan's first seconds (RoomBoundary.PausesHands),
    // so a button may need a screen tap at first. The panel follows the head lazily, as the user
    // looks around. Before the home screen, this scan ran in the lobby and blocked every cold start.
    // Lives in the Core scene. Logs [Scan].
    public class RoomScanPrompt : MonoBehaviour
    {
        const float k_Distance = 1.5f;
        // Below the line of sight, so it covers less of what the app itself shows.
        const float k_Pitch = -14f;
        const float k_DeadZone = 35f;

        [SerializeField] CoreServices m_Core;

        bool m_Ending;
        Coroutine m_Running;
        RectTransform m_Panel;
        TMP_Text m_Status;
        M3Button m_Button;
        float m_Yaw;
        bool m_Following;
        float m_YawSpeed;

        public bool IsShowing => m_Running != null;

        void Awake()
        {
            if (m_Core != null && m_Core.Demos != null)
                m_Core.Demos.Loaded += OnLoaded;
        }

        void OnDestroy()
        {
            if (m_Core != null && m_Core.Demos != null)
                m_Core.Demos.Loaded -= OnLoaded;
        }

        // Another scene: the scan this was for is over, whatever it found.
        void OnLoaded(DemoCatalog.Entry entry) => Hide();

        // Shows the panel for a scan RoomBoundary.ScanRoom has started.
        public void Show()
        {
            Hide();
            Build();
            m_Ending = false;
            m_Yaw = HeadYaw();
            m_Following = false;
            m_YawSpeed = 0f;
            UpdatePanel(false);
            M3Fade.Show(m_Panel.gameObject);
            m_Running = StartCoroutine(Run());
        }

        public void Hide()
        {
            if (m_Running != null)
                StopCoroutine(m_Running);
            m_Running = null;
            if (m_Panel != null)
                M3Fade.Hide(m_Panel.gameObject);
        }

        IEnumerator Run()
        {
            var boundary = m_Core.Boundary;
            var started = Time.unscaledTime;
            var tracked = false;
            Debug.Log("[Scan] Scanning the room");

            string how;
            while (true)
            {
                tracked |= m_Core.Fusion.IsArTracking;
                if (m_Ending)
                {
                    how = boundary.HasFloor ? "done" : "skipped";
                    boundary.FinishScan();
                    break;
                }
                if (m_Core.Fusion.CurrentMode != HeadPoseFusion.Mode.SixDof)
                {
                    how = "given up: 6DoF ended";
                    boundary.FinishScan();
                    break;
                }
                if (tracked && !boundary.IsScanning)
                {
                    how = "finished";
                    break;
                }
                UpdatePanel(tracked);
                yield return null;
            }
            Debug.Log($"[Scan] Room scan {how} after {Time.unscaledTime - started:F0} s: " +
                      $"{boundary.SurfaceCount} surfaces, {boundary.SurfaceArea:F1} m2, {(boundary.HasFloor ? "floor found" : "no floor")}");
            m_Running = null;
            M3Fade.Hide(m_Panel.gameObject);
        }

        // Done once the floor's found, Skip before.
        void End() => m_Ending = true;

        void UpdatePanel(bool tracked)
        {
            var boundary = m_Core.Boundary;
            var count = boundary.SurfaceCount;
            m_Status.text = !tracked ? "Starting tracking… move the phone a little."
                : count == 0 ? "No surfaces yet. Look down at the floor."
                : $"{count} surface{(count == 1 ? "" : "s")}, {boundary.SurfaceArea:F1} m²" +
                  (boundary.HasFloor ? ", floor found" : ". Look down at the floor.");
            var label = boundary.HasFloor ? "Done" : "Skip";
            if (m_Button.Text != label)
                m_Button.Text = label;

            // Lazily in front of the head, as the user looks around the room.
            m_Yaw = SettingsSummoner.FollowYaw(m_Yaw, HeadYaw(), k_DeadZone, ref m_Following, ref m_YawSpeed, Time.unscaledDeltaTime);
            var head = m_Core.Head.position;
            var direction = Quaternion.Euler(-k_Pitch, m_Yaw, 0f) * Vector3.forward;
            var position = head + direction * k_Distance;
            m_Panel.SetPositionAndRotation(position, Quaternion.LookRotation(direction, Vector3.up));
        }

        float HeadYaw()
        {
            var flat = Vector3.ProjectOnPlane(m_Core.Head.forward, Vector3.up);
            return flat.sqrMagnitude > 1e-4f ? Quaternion.LookRotation(flat.normalized).eulerAngles.y : m_Yaw;
        }

        // A small Material panel: what to do, what's been found, and Skip (Done once there's a floor).
        void Build()
        {
            if (m_Panel != null)
                return;
            m_Panel = WorldUi.Panel("Room Scan", transform, new Vector2(440f, 196f), k_Distance);
            M3.Icon("Icon", m_Panel, "radar", 24f, new Vector2(-196f + 12f, 62f), M3Theme.Primary);
            M3.Text("Title", m_Panel, "Scanning your room", M3Theme.Type.TitleLarge, new Vector2(16f, 62f), new Vector2(360f, 30f),
                alignment: TextAlignmentOptions.Left);
            M3.Text("Body", m_Panel, "Look around slowly, at the floor and any tables.", M3Theme.Type.BodyMedium, new Vector2(0f, 24f),
                new Vector2(392f, 20f), alignment: TextAlignmentOptions.Left);
            m_Status = M3.Text("Status", m_Panel, "", M3Theme.Type.BodyMedium, new Vector2(0f, -6f), new Vector2(392f, 20f),
                M3Theme.OnSurfaceVariant, TextAlignmentOptions.Left);
            const float width = 112f;
            m_Button = M3.Button("End Scan", m_Panel, "Skip", M3Button.Variant.Tonal, new Vector2(220f - 24f - width / 2f, -58f), End,
                width: width);
            m_Panel.gameObject.SetActive(false);
        }
    }
}
