using System;
using System.Collections.Generic;
using Afterglow.Hands;
using Afterglow.Stereo;
using Afterglow.UI;
using TMPro;
using UnityEngine;

namespace Afterglow.Demos
{
    // The settings screen: the knobs that used to be launch options from a Mac, as rows a gaze can
    // change -- look at the minus or plus beside a value and pinch or tap. It stands above the
    // settings panel where the home screen does, shown by the panel's Settings button or the home
    // screen's Settings tile; the two share the spot, so showing one hides the other. Everything is saved (Settings) and most of it
    // applies at once; the rest says so in the note at the bottom. Logs [Settings].
    public class SettingsScreen : MonoBehaviour
    {
        public const float k_Width = 560f;
        const float k_Row = 56f;
        const int k_RowsPerPage = 5;
        const float k_Padding = 16f;
        const float k_Header = 32f;
        const float k_Footer = 56f;
        const float k_Gap = 8f;
        const float k_LabelWidth = 230f;
        const float k_ValueWidth = 150f;
        const string k_NextLaunch = "Takes effect at the next launch";

        [SerializeField] SettingsSummoner m_Settings;
        [SerializeField] HomeScreen m_Home;
        [SerializeField] StereoRig m_Rig;
        [Tooltip("The settings panel's Settings button, shown selected while the screen shows.")]
        [SerializeField] M3Button m_Button;
        [Tooltip("The screen's surface, above the settings panel, shown and hidden.")]
        [SerializeField] RectTransform m_Root;

        // One row: a setting, the values it steps through, and how to show and apply one.
        class Setting
        {
            public string Key;
            public string Label;
            public int[] Choices;
            public int Fallback;
            public Func<int, string> Show;
            // Null means Settings.Saved / Settings.Set under Key.
            public Func<int> Read;
            public Action<int> Write;
            // Run after a change, for what doesn't watch Settings.Changed itself.
            public Action Apply;
            public string Note;

            public int Value => Read != null ? Read() : Settings.Saved(Key, Fallback);

            public void SetValue(int value)
            {
                if (Write != null)
                    Write(value);
                else
                    Settings.Set(Key, value);
                Apply?.Invoke();
            }

            public void Reset()
            {
                if (Write != null)
                    Write(Fallback);
                else
                    Settings.Clear(Key);
                Apply?.Invoke();
            }
        }

        readonly List<Setting> m_Rows = new();
        readonly List<(TMP_Text label, TMP_Text value, M3Button less, M3Button more)> m_Views = new();
        TMP_Text m_PageLabel;
        TMP_Text m_Note;
        M3Button m_Previous;
        M3Button m_Next;
        int m_Page;
        bool m_Built;

        public static Vector2 Size =>
            new(k_Width, 2f * k_Padding + k_Header + k_Gap + k_RowsPerPage * k_Row + k_Gap + k_Footer);

        public bool IsShown => m_Root != null && M3Fade.IsShown(m_Root.gameObject);

        void Awake()
        {
            if (m_Settings != null)
                m_Settings.OpenChanged += OnSettingsOpenChanged;
            if (m_Home != null)
                m_Home.Shown += OnHomeShown;
        }

        void OnDestroy()
        {
            if (m_Settings != null)
                m_Settings.OpenChanged -= OnSettingsOpenChanged;
            if (m_Home != null)
                m_Home.Shown -= OnHomeShown;
        }

        // The panel's Settings button.
        public void Toggle() => Show(!IsShown);

        public void Show(bool show)
        {
            if (show)
            {
                Build();
                if (m_Home != null && m_Home.IsShown)
                    m_Home.Show(false);
                if (m_Settings != null)
                    m_Settings.Above = m_Root;
            }
            M3Fade.SetShown(m_Root.gameObject, show);
            if (m_Button != null)
                m_Button.Selected = show;
            if (show)
            {
                m_Note.text = "";
                Refresh();
                Debug.Log("[Settings] Screen shown");
            }
        }

        // Closed with the panel, so it opens next time as the panel alone.
        void OnSettingsOpenChanged(bool open)
        {
            if (!open && IsShown)
                Show(false);
        }

        // The home screen took the spot above the panel.
        void OnHomeShown(bool shown)
        {
            if (shown && IsShown)
                Show(false);
        }

        static int[] Range(int from, int to, int step)
        {
            var values = new List<int>();
            for (var v = from; v <= to; v += step)
                values.Add(v);
            return values.ToArray();
        }

        // The rows, in the order they show. A key is both the launch option and the saved setting.
        void DefineRows()
        {
            m_Rows.Clear();
            void Rig() { if (m_Rig != null) m_Rig.ApplySettings(); }

            m_Rows.Add(new Setting
            {
                Key = "fps", Label = "Frame rate", Choices = new[] { 60, 90, 120 }, Fallback = 60,
                Show = v => $"{v} fps", Apply = Rig,
            });
            m_Rows.Add(new Setting
            {
                Key = "renderScale", Label = "Render scale", Choices = Range(50, 150, 10), Fallback = 100,
                Show = v => $"{v} %", Apply = Rig,
            });
            m_Rows.Add(new Setting
            {
                Key = "msaa", Label = "Anti-aliasing", Choices = new[] { 1, 2, 4 }, Fallback = 2,
                Show = v => v <= 1 ? "Off" : $"{v}×", Apply = Rig,
            });
            // The focus wheel's offset lives in ViewerFocus, in meters; here in tenths of a millimeter.
            m_Rows.Add(new Setting
            {
                Key = "focus", Label = "Focus wheel", Choices = Range(-120, 120, 5), Fallback = 0,
                Show = v => v == 0 ? "As the profile" : $"{v / 10f:+0.0;-0.0} mm",
                Read = () => Mathf.RoundToInt(ViewerFocus.Offset * 10000f),
                Write = v => ViewerFocus.Offset = v * 0.0001f,
            });
            m_Rows.Add(new Setting
            {
                Key = "brightness", Label = "Screen brightness", Choices = new[] { 0, 50, 60, 70, 80, 90, 100 }, Fallback = 90,
                Show = v => v <= 0 ? "Phone's own" : $"{v} %",
            });
            m_Rows.Add(new Setting
            {
                Key = "uiScale", Label = "UI size", Choices = Range(100, 220, 10), Fallback = 160,
                Show = v => $"{v} %", Note = k_NextLaunch,
            });
            m_Rows.Add(new Setting
            {
                Key = "showHands", Label = "Show tracked hands", Choices = new[] { 0, 1 }, Fallback = 0,
                Show = v => v == 1 ? "On, over the camera image" : "Off",
                Note = "Draws the tracked joints over your real hands, to see how well the tracking follows them.",
            });
            m_Rows.Add(new Setting
            {
                Key = "handHz", Label = "Hand tracking rate", Choices = new[] { 0, 10, 15, 20, 30 }, Fallback = 0,
                Show = v => v <= 0 ? "Every image" : $"{v} a second",
            });
            m_Rows.Add(new Setting
            {
                Key = "dof", Label = "Start in", Choices = new[] { 3, 6 }, Fallback = 6,
                Show = v => v == 6 ? "6DoF, room tracked" : "3DoF, head only", Note = k_NextLaunch,
            });
            m_Rows.Add(new Setting
            {
                // Scanning the whole room when an app that places things on it opens (DemoManager);
                // off, 6DoF still finds the floor by itself.
                Key = "scan", Label = "Scan the room for apps", Choices = new[] { 0, 1 }, Fallback = 1,
                Show = v => v != 0 ? "On" : "Floor only",
            });
            m_Rows.Add(new Setting
            {
                Key = "boundaryCm", Label = "Boundary warning", Choices = new[] { 0, 30, 50, 80 }, Fallback = 0,
                Show = v => v <= 0 ? "Off" : $"Within {v} cm",
            });
            // The camera sees less than the lenses show: magnified, the room fills the view and
            // looks nearer than life; at true scale it is a window with a border.
            m_Rows.Add(new Setting
            {
                Key = "ptFill", Label = "Passthrough", Choices = new[] { 0, 1 }, Fallback = 1,
                Show = v => v != 0 ? "Fills the view" : "True size, a window",
            });
        }

        int Pages => (m_Rows.Count + k_RowsPerPage - 1) / k_RowsPerPage;

        void Build()
        {
            if (m_Built)
                return;
            m_Built = true;
            DefineRows();
            var size = Size;
            var top = size.y / 2f - k_Padding;

            M3.Icon("Icon", m_Root, "tune", 24f, new Vector2(-size.x / 2f + k_Padding + 12f, top - k_Header / 2f), M3Theme.Primary);
            M3.Text("Title", m_Root, "Settings", M3Theme.Type.TitleLarge,
                new Vector2(20f, top - k_Header / 2f), new Vector2(size.x - 2f * k_Padding - 40f, k_Header),
                alignment: TextAlignmentOptions.Left);

            var rowsTop = top - k_Header - k_Gap;
            for (var i = 0; i < k_RowsPerPage; i++)
            {
                var y = rowsTop - k_Row / 2f - i * k_Row;
                var label = M3.Text($"Label {i}", m_Root, "", M3Theme.Type.BodyLarge,
                    new Vector2(-size.x / 2f + k_Padding + k_LabelWidth / 2f, y), new Vector2(k_LabelWidth, k_Row),
                    alignment: TextAlignmentOptions.Left);
                var value = M3.Text($"Value {i}", m_Root, "", M3Theme.Type.BodyLarge,
                    new Vector2(-size.x / 2f + k_Padding + k_LabelWidth + k_Gap + k_ValueWidth / 2f, y),
                    new Vector2(k_ValueWidth, k_Row), M3Theme.OnSurfaceVariant);
                var row = i;
                var less = M3.IconButton($"Less {i}", m_Root, "remove", M3Button.Variant.Tonal,
                    new Vector2(size.x / 2f - k_Padding - M3Theme.k_Target * 1.5f - k_Gap, y), () => Step(row, -1), 48f);
                var more = M3.IconButton($"More {i}", m_Root, "add", M3Button.Variant.Tonal,
                    new Vector2(size.x / 2f - k_Padding - M3Theme.k_Target / 2f, y), () => Step(row, +1), 48f);
                m_Views.Add((label, value, less, more));
            }

            var footerY = -size.y / 2f + k_Padding + k_Footer / 2f;
            M3.Button("Defaults", m_Root, "Defaults", M3Button.Variant.Text,
                new Vector2(-size.x / 2f + k_Padding + 70f, footerY), ResetAll, "restart_alt", 140f);
            m_Note = M3.Text("Note", m_Root, "", M3Theme.Type.BodyMedium,
                new Vector2(-20f, footerY), new Vector2(230f, k_Footer), M3Theme.OnSurfaceVariant);
            m_Previous = M3.IconButton("Previous Page", m_Root, "chevron_left", M3Button.Variant.Tonal,
                new Vector2(size.x / 2f - k_Padding - M3Theme.k_Target * 1.5f - k_Gap - 60f, footerY), () => Turn(-1), 48f);
            m_PageLabel = M3.Text("Page", m_Root, "", M3Theme.Type.LabelLarge,
                new Vector2(size.x / 2f - k_Padding - M3Theme.k_Target - k_Gap / 2f - 30f, footerY), new Vector2(60f, k_Footer),
                M3Theme.OnSurfaceVariant);
            m_Next = M3.IconButton("Next Page", m_Root, "chevron_right", M3Button.Variant.Tonal,
                new Vector2(size.x / 2f - k_Padding - M3Theme.k_Target / 2f, footerY), () => Turn(+1), 48f);
        }

        void Turn(int by)
        {
            m_Page = Mathf.Clamp(m_Page + by, 0, Pages - 1);
            Refresh();
        }

        Setting RowAt(int viewIndex)
        {
            var index = m_Page * k_RowsPerPage + viewIndex;
            return index < m_Rows.Count ? m_Rows[index] : null;
        }

        void Step(int viewIndex, int by)
        {
            var setting = RowAt(viewIndex);
            if (setting == null)
                return;
            var choices = setting.Choices;
            var current = setting.Value;
            // The nearest choice to what's set, so a value from a launch option still steps sensibly.
            var at = 0;
            for (var i = 1; i < choices.Length; i++)
            {
                if (Mathf.Abs(choices[i] - current) < Mathf.Abs(choices[at] - current))
                    at = i;
            }
            var next = Mathf.Clamp(at + by, 0, choices.Length - 1);
            if (choices[next] == current)
                return;
            setting.SetValue(choices[next]);
            m_Note.text = setting.Note ?? "";
            Refresh();
        }

        void ResetAll()
        {
            foreach (var setting in m_Rows)
                setting.Reset();
            m_Note.text = k_NextLaunch + " for some";
            Debug.Log("[Settings] Everything back to its defaults");
            Refresh();
        }

        void Refresh()
        {
            for (var i = 0; i < m_Views.Count; i++)
            {
                var (label, value, less, more) = m_Views[i];
                var setting = RowAt(i);
                var has = setting != null;
                label.gameObject.SetActive(has);
                value.gameObject.SetActive(has);
                less.gameObject.SetActive(has);
                more.gameObject.SetActive(has);
                if (!has)
                    continue;
                label.text = setting.Label;
                var current = setting.Value;
                value.text = setting.Show(current);
                less.Interactable = current > setting.Choices[0];
                more.Interactable = current < setting.Choices[setting.Choices.Length - 1];
            }
            m_PageLabel.text = $"{m_Page + 1} / {Pages}";
            m_Previous.Interactable = m_Page > 0;
            m_Next.Interactable = m_Page < Pages - 1;
        }
    }
}
