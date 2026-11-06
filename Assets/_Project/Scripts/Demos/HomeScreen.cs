using System.Collections.Generic;
using Afterglow.Hands;
using Afterglow.Stereo;
using Afterglow.UI;
using TMPro;
using UnityEngine;
using UnityEngine.UI;

namespace Afterglow.Demos
{
    // The home screen: what the app opens on and comes back to, above the settings panel, which its
    // Home button shows and hides. A grid of five sections -- Media (the Photos library's spatial
    // photos and videos, and 360 films), Web (the WebXR browser), Files (videos copied to the phone),
    // Play (the games and the room) and Settings -- with a one-line tagline under the grid for the
    // one being looked at. Play turns the page to the games, one tile per catalog entry in that
    // section, with a back arrow to the sections. The section or game running now is marked with a
    // dot under its name, and Leave, in the header while one runs, goes back to the Home scene.
    // Picking anything closes the panel and opens it, from wherever you are, so there's no need to go
    // home between apps (DemoManager restores what one app switched on before applying the next's
    // needs). Entering the Home scene opens the panel with this showing (Open, on DemoManager.Loaded),
    // as it does at the start. Part of the settings panel, so it follows the panel and closes with
    // it. Built at runtime inside m_Root, so a new section is a line in Sections and a new game a
    // catalog entry. Lives on an object that's always active (the Demos object). Logs [Home].
    public class HomeScreen : MonoBehaviour
    {
        public enum Section
        {
            Media,
            Web,
            Files,
            Play,
            Settings,
        }

        // One tile of the sections page. Pure data, so the page can be checked without a scene.
        public struct Tile
        {
            public Section Section;
            public string Title;
            public string Tagline;
            public string Icon;
            public Color Tint;
            public bool Enabled;
        }

        // In dp: each tile's cell, its icon square, the header above the grid, and the gaps between
        // cells and around the grid.
        public const float k_CellWidth = 128f;
        // Kept short, so the grid sits at eye level with the settings panel close below it.
        public const float k_CellHeight = 124f;
        const float k_IconSize = 72f;
        const float k_IconRadius = 18f;
        const float k_Gap = 8f;
        const float k_Padding = 16f;
        const float k_TaglineHeight = 28f;
        public const float k_Header = 40f;
        public const int k_Columns = 3;
        public const int k_SectionCount = 5;
        const string k_Prompt = "Look at something to see what it is";
        // The argument Files enters the media player with, so it lists only the files (VideoDemo).
        public const string k_FilesArgument = "files";
        // Picks this soon after the screen appears are ignored: it opens where the user is looking,
        // and the pinch that opened it (or a flicker of it) landed on a tile 0.6 s later, reopening the
        // app just left.
        const float k_PickGuardSeconds = 0.8f;

        [SerializeField] DemoManager m_Demos;
        [SerializeField] SettingsSummoner m_Settings;
        [Tooltip("The settings screen, which the Settings tile shows in this screen's place.")]
        [SerializeField] SettingsScreen m_SettingsScreen;
        [Tooltip("The browser, which the Web tile opens.")]
        [SerializeField] WebBrowserSession m_Browser;
        [Tooltip("The settings panel's Home button, shown selected while the screen shows.")]
        [SerializeField] M3Button m_HomeButton;
        [Tooltip("The screen's surface, above the settings panel, shown and hidden.")]
        [SerializeField] RectTransform m_Root;

        RectTransform m_SectionsPage;
        RectTransform m_PlayPage;
        TMP_Text m_Title;
        TMP_Text m_Tagline;
        GameObject m_HomeIcon;
        M3Button m_Back;
        M3Button m_Leave;
        readonly Dictionary<Section, GameObject> m_SectionDots = new();
        readonly List<(DemoCatalog.Entry entry, GameObject running)> m_PlayTiles = new();
        float m_ShownAt = float.NegativeInfinity;
        bool m_Built;

        public bool IsShown => m_Root != null && M3Fade.IsShown(m_Root.gameObject);
        public bool IsOnPlay => m_PlayPage != null && m_PlayPage.gameObject.activeSelf;

        // Shown (true) or hidden (false), for what shares its spot above the panel (SettingsScreen).
        public event System.Action<bool> Shown;

        // The sections, in the order they show. Web needs the in-app browser, which is iOS only.
        public static Tile[] Sections(bool webSupported) => new[]
        {
            new Tile
            {
                Section = Section.Media, Title = "Media", Icon = "photo_library", Tint = new Color(0.7f, 0.25f, 0.29f), Enabled = true,
                Tagline = "Spatial photos and videos from your Photos library, and 360 films",
            },
            new Tile
            {
                Section = Section.Web, Title = "Web", Icon = "public", Tint = new Color(0.12f, 0.55f, 0.62f), Enabled = webSupported,
                Tagline = webSupported ? "WebXR pages, in a window or all around you" : "The browser is iOS only",
            },
            new Tile
            {
                Section = Section.Files, Title = "Files", Icon = "folder", Tint = new Color(0.78f, 0.49f, 0.12f), Enabled = true,
                Tagline = "Videos copied to the phone, and links to download",
            },
            new Tile
            {
                Section = Section.Play, Title = "Play", Icon = "sports_esports", Tint = new Color(0.48f, 0.31f, 0.75f), Enabled = true,
                Tagline = "The games, and a room to look around",
            },
            new Tile
            {
                Section = Section.Settings, Title = "Settings", Icon = "tune", Tint = new Color(0.29f, 0.36f, 0.54f), Enabled = true,
                Tagline = "Frame rate, lenses, hands and the rest",
            },
        };

        // The screen's size in dp for a page of this many tiles (the larger page sizes it).
        public static Vector2 Size(int tiles)
        {
            var rows = Mathf.Max(1, (tiles + k_Columns - 1) / k_Columns);
            return new Vector2(k_Columns * k_CellWidth + (k_Columns - 1) * k_Gap + 2f * k_Padding,
                2f * k_Padding + k_Header + k_Gap + rows * k_CellHeight + (rows - 1) * k_Gap + k_Gap + k_TaglineHeight);
        }

        // Where a tile's cell goes, its middle from the screen's middle, in dp: left to right, then
        // the next row, under the header.
        public static Vector2 CellPosition(int index, Vector2 size)
        {
            var column = index % k_Columns;
            var row = index / k_Columns;
            var x = -size.x / 2f + k_Padding + k_CellWidth / 2f + column * (k_CellWidth + k_Gap);
            var y = size.y / 2f - k_Padding - k_Header - k_Gap - k_CellHeight / 2f - row * (k_CellHeight + k_Gap);
            return new Vector2(x, y);
        }

        void Awake()
        {
            if (m_Settings != null)
                m_Settings.OpenChanged += OnSettingsOpenChanged;
            if (m_Demos != null)
                m_Demos.Loaded += OnLoaded;
        }

        void OnDestroy()
        {
            if (m_Settings != null)
                m_Settings.OpenChanged -= OnSettingsOpenChanged;
            if (m_Demos != null)
                m_Demos.Loaded -= OnLoaded;
        }

        // The panel's Home button.
        public void Toggle() => Show(!IsShown);

        public void Show(bool show)
        {
            if (show)
            {
                Build();
                if (!IsShown)
                    m_ShownAt = Time.unscaledTime;
                if (m_Settings != null)
                    m_Settings.Above = m_Root;
            }
            M3Fade.SetShown(m_Root.gameObject, show);
            Shown?.Invoke(show);
            if (m_HomeButton != null)
                m_HomeButton.Selected = show;
            if (show)
                ShowSections();
        }

        // The settings panel, opened in front of the user, with the sections showing: how the Home
        // scene greets the user, and how the app starts.
        public void Open()
        {
            if (m_Settings != null)
                m_Settings.Open();
            Show(true);
        }

        // The Play tile, and the back arrow's opposite.
        public void ShowPlay()
        {
            Build();
            m_SectionsPage.gameObject.SetActive(false);
            m_PlayPage.gameObject.SetActive(true);
            m_Title.text = "Play";
            m_Back.gameObject.SetActive(true);
            m_HomeIcon.SetActive(false);
            m_Leave.gameObject.SetActive(false);
            m_Tagline.text = k_Prompt;
            MarkRunning();
        }

        public void ShowSections()
        {
            Build();
            m_SectionsPage.gameObject.SetActive(true);
            m_PlayPage.gameObject.SetActive(false);
            m_Title.text = "Afterglow";
            m_Back.gameObject.SetActive(false);
            m_HomeIcon.SetActive(true);
            m_Leave.gameObject.SetActive(m_Demos != null && m_Demos.Current != null);
            m_Tagline.text = k_Prompt;
            MarkRunning();
        }

        // Entering the Home scene opens the screen; entering anything else while it's up only
        // moves the dot.
        void OnLoaded(DemoCatalog.Entry entry)
        {
            if (entry == null)
                Open();
            else if (IsShown)
                ShowSections();
        }

        // Closed with the panel, so it opens next time as the panel alone.
        void OnSettingsOpenChanged(bool open)
        {
            if (!open && IsShown)
                Show(false);
        }

        bool Guarded(string what)
        {
            if (Time.unscaledTime - m_ShownAt >= k_PickGuardSeconds)
                return false;
            Debug.Log($"[Home] Ignored a pick of {what} {Time.unscaledTime - m_ShownAt:F2} s after the screen appeared");
            return true;
        }

        void PickSection(Section section)
        {
            if (Guarded(section.ToString()))
                return;
            switch (section)
            {
                case Section.Play:
                    Debug.Log("[Home] Picked Play");
                    ShowPlay();
                    return;
                case Section.Settings:
                    Debug.Log("[Home] Picked Settings");
                    if (m_SettingsScreen != null)
                        m_SettingsScreen.Show(true);
                    return;
                case Section.Web:
                    Debug.Log("[Home] Picked Web");
                    // Open closes the panel itself, so the page gets the pinches.
                    if (m_Browser != null)
                        m_Browser.Open();
                    return;
                case Section.Media:
                case Section.Files:
                    Debug.Log($"[Home] Picked {section}");
                    if (m_Settings != null)
                        m_Settings.Close();
                    var player = MediaEntry();
                    if (player == null)
                    {
                        Debug.LogError("[Home] The catalog has no Media entry, so there's no player to open");
                        return;
                    }
                    m_Demos.Enter(player, section == Section.Files ? k_FilesArgument : null);
                    return;
            }
        }

        void PickGame(DemoCatalog.Entry entry)
        {
            if (Guarded(entry.Title))
                return;
            if (m_Settings != null)
                m_Settings.Close();
            if (entry == m_Demos.Current)
            {
                Debug.Log($"[Home] Picked {entry.Title}: already running");
                return;
            }
            Debug.Log($"[Home] Picked {entry.Title}");
            m_Demos.Enter(entry);
        }

        // Leave, in the header: out of the running app and back to the Home scene, where the screen
        // opens again.
        void Leave()
        {
            if (Guarded("Leave") || m_Demos.Current == null)
                return;
            Debug.Log($"[Home] Leaving {m_Demos.Current.Title}");
            if (m_Settings != null)
                m_Settings.Close();
            m_Demos.ExitToHome();
        }

        // The catalog's player: the first entry in the Media section.
        DemoCatalog.Entry MediaEntry()
        {
            if (m_Demos == null || m_Demos.Catalog == null)
                return null;
            var media = m_Demos.Catalog.InSection(DemoCatalog.Section.Media);
            return media.Count > 0 ? media[0] : null;
        }

        // Which section is running, if any, for the dot under its name. Pure, for testing.
        public static Section? Running(DemoCatalog.Entry current, string argument, bool browserOpen)
        {
            if (browserOpen)
                return Section.Web;
            if (current == null)
                return null;
            if (current.Section == DemoCatalog.Section.Media)
                return argument == k_FilesArgument ? Section.Files : Section.Media;
            return Section.Play;
        }

        void MarkRunning()
        {
            var running = Running(m_Demos != null ? m_Demos.Current : null, m_Demos != null ? m_Demos.Argument : null,
                WebBrowser.IsOpen);
            foreach (var (section, dot) in m_SectionDots)
                dot.SetActive(running == section);
            foreach (var (entry, dot) in m_PlayTiles)
                dot.SetActive(m_Demos != null && entry == m_Demos.Current);
        }

        // The header, the two pages and the tagline; once.
        void Build()
        {
            if (m_Built || m_Root == null)
                return;
            m_Built = true;
            var size = m_Root.sizeDelta;
            var top = size.y / 2f - k_Padding;

            m_Back = M3.IconButton("Back", m_Root, "arrow_back", M3Button.Variant.Text,
                new Vector2(-size.x / 2f + k_Padding + k_Header / 2f, top - k_Header / 2f), ShowSections, k_Header);
            m_HomeIcon = M3.Icon("Home Icon", m_Root, "home", 24f, new Vector2(-size.x / 2f + k_Padding + k_Header / 2f, top - k_Header / 2f),
                M3Theme.Primary).gameObject;
            m_Title = M3.Text("Title", m_Root, "Afterglow", M3Theme.Type.TitleLarge,
                new Vector2(k_Header / 2f + k_Gap / 2f, top - k_Header / 2f), new Vector2(size.x - 2f * k_Padding - k_Header - k_Gap - 120f, k_Header),
                alignment: TextAlignmentOptions.Left);
            const float leaveWidth = 112f;
            m_Leave = M3.Button("Leave", m_Root, "Leave", M3Button.Variant.Text,
                new Vector2(size.x / 2f - k_Padding - leaveWidth / 2f, top - k_Header / 2f), Leave, "close", leaveWidth);
            m_Tagline = M3.Text("Tagline", m_Root, k_Prompt, M3Theme.Type.BodyMedium,
                new Vector2(0f, -size.y / 2f + k_Padding + k_TaglineHeight / 2f), new Vector2(size.x - 2f * k_Padding, k_TaglineHeight),
                M3Theme.OnSurfaceVariant);
            m_Back.gameObject.AddComponent<AppTileGaze>().Initialize(m_Tagline, "Back to the sections", k_Prompt);
            m_Leave.gameObject.AddComponent<AppTileGaze>().Initialize(m_Tagline, "Leave what's running and go home", k_Prompt);

            m_SectionsPage = M3.Group("Sections", m_Root, Vector2.zero, size);
            var sections = Sections(WebBrowser.Supported);
            for (var i = 0; i < sections.Length; i++)
            {
                var tile = sections[i];
                var dot = MakeTile(m_SectionsPage, i, size, tile.Title, tile.Tagline, tile.Icon, tile.Tint, tile.Enabled,
                    () => PickSection(tile.Section));
                m_SectionDots[tile.Section] = dot;
            }

            m_PlayPage = M3.Group("Play", m_Root, Vector2.zero, size);
            var games = m_Demos != null && m_Demos.Catalog != null
                ? m_Demos.Catalog.InSection(DemoCatalog.Section.Play)
                : new List<DemoCatalog.Entry>();
            for (var i = 0; i < games.Count; i++)
            {
                var entry = games[i];
                var dot = MakeTile(m_PlayPage, i, size, entry.Title, entry.Tagline, entry.Icon, entry.Tint, true, () => PickGame(entry));
                m_PlayTiles.Add((entry, dot));
            }
            // The back arrow sits where the home icon does; one shows at a time (ShowSections, ShowPlay).
            m_Back.gameObject.SetActive(false);
            m_PlayPage.gameObject.SetActive(false);
        }

        // One tile: an icon on a colored rounded square over its name, the whole cell the target, with
        // a state layer behind it for the gaze, and a dot under the name while it's running. Returns
        // the dot. A disabled tile is dimmed and says why in its tagline.
        GameObject MakeTile(RectTransform page, int index, Vector2 size, string title, string tagline, string icon, Color tint, bool enabled,
            UnityEngine.Events.UnityAction onClick)
        {
            var cell = M3.Group($"Tile {title}", page, CellPosition(index, size), new Vector2(k_CellWidth, k_CellHeight));
            var state = M3.Surface("State Layer", cell, Vector2.zero, cell.sizeDelta, Color.clear, M3Theme.k_ShapeLarge,
                raycastTarget: true);
            var button = cell.gameObject.AddComponent<Button>();
            button.transition = Selectable.Transition.None;
            button.targetGraphic = state;
            button.interactable = enabled;
            if (enabled)
                button.onClick.AddListener(onClick);
            cell.gameObject.AddComponent<M3StateLayer>().Initialize(state, button, M3Theme.OnSurface);

            var dim = enabled ? 1f : M3Theme.k_DisabledContent;
            var square = M3.Surface("Icon Square", cell, new Vector2(0f, 16f), new Vector2(k_IconSize, k_IconSize),
                M3Theme.WithAlpha(tint, dim), k_IconRadius);
            M3.Icon("Icon", square.rectTransform, icon, 40f, Vector2.zero, M3Theme.WithAlpha(Color.white, dim));
            var name = M3.Text("Name", cell, title, M3Theme.Type.LabelLarge, new Vector2(0f, -36f), new Vector2(k_CellWidth - 8f, 20f),
                M3Theme.WithAlpha(M3Theme.OnSurface, dim));
            name.textWrappingMode = TextWrappingModes.NoWrap;
            var running = M3.Surface("Running", cell, new Vector2(0f, -53f), new Vector2(6f, 6f), M3Theme.Primary, M3Theme.k_ShapeFull)
                .gameObject;
            running.SetActive(false);
            cell.gameObject.AddComponent<AppTileGaze>().Initialize(m_Tagline, string.IsNullOrEmpty(tagline) ? title : tagline, k_Prompt);
            return running;
        }
    }
}
