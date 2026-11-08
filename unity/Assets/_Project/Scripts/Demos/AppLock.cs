using System;
using System.Security.Cryptography;
using System.Text;
using Afterglow.Hands;
using Afterglow.Interaction;
using Afterglow.Stereo;
using Afterglow.UI;
using TMPro;
using UnityEngine;

namespace Afterglow.Demos
{
    // An optional six-digit PIN, asked for when the app opens and after a minute away, so a
    // viewer left on a table doesn't open the browser or the library to whoever picks it up.
    // Turned on and off in Settings ("App PIN"). What is kept is a salted hash in the phone's
    // Keychain (never the PIN, never in a log); off iOS there is no Keychain, so no PIN.
    //
    // The panel is a keypad in front of the head: look at a digit and pinch or tap, as with any
    // button. While it shows it takes every pinch (IPinchHandler) and keeps the settings panel
    // shut, so nothing behind it can be reached. Five wrong PINs mean a thirty-second wait.
    public class AppLock : MonoBehaviour, IPinchHandler
    {
        public const string Service = "afterglow.lock";
        public const string Account = "pin";
        public const int Digits = 6;
        const int k_MaxTries = 5;
        const float k_CooldownSeconds = 30f;
        const float k_RelockSeconds = 60f;
        const float k_Distance = 1.1f;

        enum Mode { Unlock, SetFirst, SetAgain, ClearVerify }

        static AppLock s_Instance;

        public static bool HasPin => Keychain.Supported && Keychain.Accounts(Service).Length > 0;
        public static bool IsLocked => s_Instance != null && s_Instance.m_Shown && s_Instance.m_Mode == Mode.Unlock;

        // Settings: choose a PIN (asked for twice), or enter the current one to turn it off.
        public static void BeginSet()
        {
            if (s_Instance == null || !Keychain.Supported)
                return;
            s_Instance.Show(Mode.SetFirst);
        }

        public static void BeginClear()
        {
            if (s_Instance == null || !HasPin)
                return;
            s_Instance.Show(Mode.ClearVerify);
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Create()
        {
            if (s_Instance != null)
                return;
            var go = new GameObject("App Lock");
            DontDestroyOnLoad(go);
            s_Instance = go.AddComponent<AppLock>();
        }

        // ---------------------------------------------------------------- the record
        // "salt$hash": sixteen random bytes as hex, then SHA-256 of salt + PIN as hex. Pure, so
        // the matching can be tested without a Keychain.
        public static string NewRecord(string pin)
        {
            var salt = new byte[16];
            using (var random = RandomNumberGenerator.Create())
                random.GetBytes(salt);
            var saltHex = BitConverter.ToString(salt).Replace("-", "").ToLowerInvariant();
            return saltHex + "$" + Hash(saltHex, pin);
        }

        public static string Hash(string salt, string pin)
        {
            using var sha = SHA256.Create();
            var digest = sha.ComputeHash(Encoding.UTF8.GetBytes(salt + ":" + pin));
            return BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant();
        }

        public static bool Matches(string record, string pin)
        {
            if (string.IsNullOrEmpty(record) || string.IsNullOrEmpty(pin))
                return false;
            var split = record.IndexOf('$');
            if (split <= 0)
                return false;
            var expected = record.Substring(split + 1);
            var actual = Hash(record.Substring(0, split), pin);
            // Compared in full however early they differ.
            var same = expected.Length == actual.Length;
            for (var i = 0; same && i < expected.Length; i++)
                same &= expected[i] == actual[i];
            return same;
        }

        public static bool IsPin(string text)
        {
            if (text == null || text.Length != Digits)
                return false;
            foreach (var c in text)
            {
                if (c < '0' || c > '9')
                    return false;
            }
            return true;
        }

        // ---------------------------------------------------------------- the panel
        RectTransform m_Panel;
        TextMeshProUGUI m_Title;
        TextMeshProUGUI m_Dots;
        TextMeshProUGUI m_Note;
        M3Button m_Cancel;
        Mode m_Mode;
        bool m_Shown;
        string m_Entered = "";
        string m_First;
        int m_Tries;
        float m_CooldownUntil;
        float m_PausedAt = -1f;
        IPinchHandler m_Interrupted;

        void Start()
        {
            if (HasPin)
                Show(Mode.Unlock);
        }

        void Build()
        {
            if (m_Panel != null)
                return;
            const float width = 420f, height = 640f;
            m_Panel = M3.Canvas("App Lock", transform, new Vector2(width, height), M3Theme.k_OverlayDistance,
                M3Theme.SurfaceContainerHigh, M3Theme.k_ShapePanel);
            m_Panel.gameObject.AddComponent<GazeCanvas>();
            m_Title = M3.Text("Title", m_Panel, "Enter your PIN", M3Theme.Type.TitleLarge, new Vector2(0f, height / 2f - 48f),
                new Vector2(width - 40f, 40f), M3Theme.OnSurface);
            m_Dots = M3.Text("Dots", m_Panel, "", M3Theme.Type.HeadlineSmall, new Vector2(0f, height / 2f - 100f),
                new Vector2(width - 40f, 44f), M3Theme.Primary);
            m_Note = M3.Text("Note", m_Panel, "", M3Theme.Type.BodyMedium, new Vector2(0f, height / 2f - 140f),
                new Vector2(width - 40f, 32f), M3Theme.OnSurface);
            const float pitch = 104f, top = height / 2f - 215f;
            var keys = new[] { "1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫" };
            for (var i = 0; i < keys.Length; i++)
            {
                var key = keys[i];
                if (key.Length == 0)
                    continue;
                var position = new Vector2((i % 3 - 1) * pitch, top - (i / 3) * pitch);
                var digit = key;
                M3.Button("Key " + key, m_Panel, key, M3Button.Variant.Tonal, position,
                    () => Press(digit), null, 88f);
            }
            m_Cancel = M3.Button("Cancel", m_Panel, "Cancel", M3Button.Variant.Text, new Vector2(0f, -height / 2f + 44f),
                Cancel, null, 140f);
        }

        void Show(Mode mode)
        {
            Build();
            m_Mode = mode;
            m_Entered = "";
            m_First = null;
            if (!m_Shown)
            {
                m_Shown = true;
                M3Fade.SetShown(m_Panel.gameObject, true);
                m_Interrupted = PinchRouter.Handler;
                PinchRouter.Handler = this;
                Place();
            }
            m_Cancel.gameObject.SetActive(mode != Mode.Unlock);
            Refresh();
            Debug.Log(mode == Mode.Unlock ? "[Lock] Locked; the PIN is asked for" : $"[Lock] {mode}");
        }

        void Hide()
        {
            if (!m_Shown)
                return;
            m_Shown = false;
            M3Fade.SetShown(m_Panel.gameObject, false);
            if (ReferenceEquals(PinchRouter.Handler, this))
                PinchRouter.Handler = m_Interrupted;
            m_Entered = "";
        }

        void Refresh()
        {
            var cooling = Time.unscaledTime < m_CooldownUntil;
            m_Title.text = m_Mode switch
            {
                Mode.SetFirst => "Choose a six-digit PIN",
                Mode.SetAgain => "Enter it again",
                Mode.ClearVerify => "Enter your PIN to turn it off",
                _ => "Enter your PIN",
            };
            var dots = new StringBuilder();
            for (var i = 0; i < Digits; i++)
                dots.Append(i < m_Entered.Length ? "●" : "○").Append(i < Digits - 1 ? " " : "");
            m_Dots.text = dots.ToString();
            m_Note.text = cooling ? $"Too many tries. Wait {Mathf.CeilToInt(m_CooldownUntil - Time.unscaledTime)} s." : m_NoteText;
        }
        string m_NoteText = "";

        void Press(string digit)
        {
            if (!m_Shown || Time.unscaledTime < m_CooldownUntil)
                return;
            if (digit == "⌫")
            {
                if (m_Entered.Length > 0)
                    m_Entered = m_Entered.Substring(0, m_Entered.Length - 1);
                Refresh();
                return;
            }
            if (m_Entered.Length >= Digits)
                return;
            m_Entered += digit;
            m_NoteText = "";
            Refresh();
            if (m_Entered.Length == Digits)
                Complete();
        }

        void Complete()
        {
            var pin = m_Entered;
            m_Entered = "";
            switch (m_Mode)
            {
                case Mode.SetFirst:
                    m_First = pin;
                    m_Mode = Mode.SetAgain;
                    break;
                case Mode.SetAgain:
                    if (pin != m_First)
                    {
                        m_NoteText = "They didn't match. Start again.";
                        m_Mode = Mode.SetFirst;
                        m_First = null;
                        break;
                    }
                    if (Keychain.Store(Service, Account, NewRecord(pin)))
                    {
                        Debug.Log("[Lock] PIN set");
                        Settings.Notify("appPin");
                        Hide();
                    }
                    else
                    {
                        m_NoteText = "The Keychain refused it.";
                        Debug.LogWarning("[Lock] The Keychain refused the PIN");
                    }
                    break;
                case Mode.ClearVerify:
                    if (Verify(pin))
                    {
                        Keychain.Delete(Service, Account);
                        Debug.Log("[Lock] PIN turned off");
                        Settings.Notify("appPin");
                        Hide();
                    }
                    break;
                default:
                    if (Verify(pin))
                    {
                        Debug.Log("[Lock] Unlocked");
                        Hide();
                    }
                    break;
            }
            Refresh();
        }

        // The PIN against the Keychain's record, with the tries counted and the wait after too
        // many. The PIN itself is never logged.
        bool Verify(string pin)
        {
            if (Keychain.TryLoad(Service, Account, out var record) && Matches(record, pin))
            {
                m_Tries = 0;
                return true;
            }
            m_Tries++;
            if (m_Tries >= k_MaxTries)
            {
                m_Tries = 0;
                m_CooldownUntil = Time.unscaledTime + k_CooldownSeconds;
                Debug.Log($"[Lock] Wrong PIN {k_MaxTries} times; waiting {k_CooldownSeconds:F0} s");
            }
            else
            {
                m_NoteText = $"Wrong PIN ({m_Tries} of {k_MaxTries}).";
                Debug.Log($"[Lock] Wrong PIN ({m_Tries} of {k_MaxTries})");
            }
            return false;
        }

        void Cancel()
        {
            if (m_Mode == Mode.Unlock)
                return;
            Debug.Log("[Lock] Cancelled");
            Hide();
        }

        // In front of the head, following it, so it can't be looked away from.
        void Place()
        {
            var core = CoreServices.Instance;
            if (m_Panel == null || core == null || core.Fusion == null)
                return;
            var head = core.Fusion.transform;
            var forward = head.forward;
            forward.y = 0f;
            if (forward.sqrMagnitude < 1e-4f)
                forward = Vector3.forward;
            forward.Normalize();
            m_Panel.position = head.position + forward * k_Distance;
            m_Panel.rotation = Quaternion.LookRotation(forward, Vector3.up);
        }

        void LateUpdate()
        {
            if (!m_Shown)
                return;
            Place();
            if (Time.unscaledTime < m_CooldownUntil)
                Refresh();
            // Nothing behind the lock can be reached: the settings panel (Home lives in it) stays shut.
            if (m_Mode == Mode.Unlock)
            {
                var settings = CoreServices.Instance != null ? CoreServices.Instance.Settings : null;
                if (settings != null && settings.IsOpen)
                    settings.Close();
            }
        }

        void OnApplicationPause(bool paused)
        {
            if (paused)
            {
                m_PausedAt = Time.realtimeSinceStartup;
                return;
            }
            if (m_PausedAt >= 0f && HasPin && !m_Shown && Time.realtimeSinceStartup - m_PausedAt >= k_RelockSeconds)
                Show(Mode.Unlock);
            m_PausedAt = -1f;
        }

        // Every pinch while the lock shows is its own: the keypad's buttons are pressed by the
        // router before this is asked, and anything else is swallowed.
        public bool TryBeginPinch(GameObject gazeTarget, PinchSource source) => m_Shown;
        public void EndPinch() { }
    }
}
