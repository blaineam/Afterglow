using System;
using System.IO;
using System.Collections.Generic;
using Afterglow.Hands;
using Afterglow.Interaction;
using Afterglow.Stereo;
using Afterglow.UI;
using TMPro;
using UnityEngine.UI;
using UnityEngine;

namespace Afterglow.Demos
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
        // Whether the window is following the gaze to a new place (BeginPlacing).
        bool m_Placing;
        bool m_WasTextFocused;
        // The hands for a page in a session (HandsToPage), pushed each frame while any is up and
        // once more when the last goes, so the page's hand input sources go with it.
        HandTracker m_Tracker;
        HandSubsystemFeed m_Feed;
        readonly float[] m_HandValues = new float[1 + HandTracker.MaxHands * WebBrowser.FloatsPerHand];
        int m_PushedHands;
        int m_PushedPinches;
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
        float m_LastAim;

        // Typing. Three ways in -- a Bluetooth keyboard, the keys on screen, and speech -- all
        // arriving through the same two handlers, so the page cannot tell which was used.
        WebKeyboard m_Keyboard;
        RectTransform m_Address;
        TMP_Text m_AddressText;
        M3Button m_Star;
        bool m_StarFilled;
        // The login prompt: "Save the password?" after a form is submitted, "Fill the saved
        // login?" on a page with one. One small bar above the tabs, with its two buttons.
        RectTransform m_Prompt;
        TMP_Text m_PromptText;
        M3Button m_PromptYes;
        string m_PromptHost;
        string m_PromptUser;
        string m_PromptSecret;
        bool m_PromptIsSave;
        // Bookmarks, history and the tabs, kept in the app's folder (BrowserStore).
        BrowserStore m_Store;
        float m_NextStoreSave;
        // The start page is handed its lists once its address shows, and once more a moment
        // later in case the first came before its script was ready.
        float m_FeedStartPageAt = -1f;
        bool m_OnStartPage;
        // A long press on the screen during an immersive session ends it: the page's own Exit
        // button and the app's corner gear are both out of reach from inside the viewer.
        const float k_EndPressSeconds = 1.5f;
        float m_PressedSince = -1f;
        bool m_EndRequested;
        // What is being typed into the address bar, or null while the typing is going to a field
        // on the page. Which of the two it is is the page's business, not a mode the user sets.
        string m_Typed;
        // What is being heard, shown as it fills in but not committed until the phrase ends.
        string m_Heard;
        string m_SpokenOnto;
        string m_UrlShown = "";
        float m_NextUrlPoll;
        // Tabs, as a list of addresses with one web view: switching tabs loads the other's
        // address, so a tab left behind reloads when it's returned to, and keeps nothing
        // scrolled or typed. The chips show the pages' titles.
        class Tab
        {
            public string Url;
            public string Title;
        }

        readonly List<Tab> m_Tabs = new();
        int m_Tab = -1;
        RectTransform m_TabBar;
        const int k_MaxTabs = 6;
        float m_NextHeardPoll;

        public bool IsOpen => WebBrowser.IsOpen;

        void Start()
        {
            if (LaunchOptions.GetInt("keychainTest", 0) == 1)
                Keychain.SelfTest();
        }

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
            m_Store ??= BrowserStore.Load(BrowserStore.DefaultPath);
            // The tabs come back as they were left, the selected one first on screen.
            if (m_Tabs.Count == 0 && m_Store.Tabs.Count > 0)
            {
                // The start page is kept by name: its file path changes with every install.
                foreach (var tab in m_Store.Tabs)
                    m_Tabs.Add(IsStartPage(tab.Url) || tab.Url == k_StartPageName
                        ? new Tab { Url = StartPage, Title = "Start" }
                        : new Tab { Url = tab.Url, Title = tab.Title });
                m_Tab = Mathf.Clamp(m_Store.SelectedTab, 0, m_Tabs.Count - 1);
                Debug.Log($"[WebXR] {m_Tabs.Count} tabs restored, tab {m_Tab + 1} first");
            }
            var first = m_Tab >= 0 && m_Tab < m_Tabs.Count ? m_Tabs[m_Tab].Url : StartPage;
            if (!WebBrowser.Open(first, m_Rig, m_Fusion != null && m_Fusion.IsArTracking))
                return;

            BuildWindow();
            m_Immersive = false;
            m_Tracker = CoreServices.Instance != null ? CoreServices.Instance.HandTracker : null;
            if (m_Feed == null)
                m_Feed = FindAnyObjectByType<HandSubsystemFeed>();
            // PinchRouter asks the scene's handler only while the settings panel is shut, and the
            // browser is opened from that panel -- so leaving it up means every pinch goes to its
            // buttons and the page never gets one.
            var settings = CoreServices.Instance != null ? CoreServices.Instance.Settings : null;
            if (settings != null && settings.IsOpen)
                settings.Close();
            // The window is what the pinches are for, until a page takes the screen.
            m_Interrupted = PinchRouter.Handler;
            PinchRouter.Handler = this;

            m_Keyboard = GetComponent<WebKeyboard>();
            if (m_Keyboard == null)
                m_Keyboard = gameObject.AddComponent<WebKeyboard>();
            m_Keyboard.Typed += OnTyped;
            m_Keyboard.Pressed += OnPressed;
            m_Keyboard.Dictate += OnDictate;
            KeyboardInput.Typed += OnTyped;
            KeyboardInput.Pressed += OnPressed;
        }

        public void Close()
        {
            // Input and the microphone first, and whether or not the page is still up: these are
            // static events, and a handler left subscribed to one outlives the browser that
            // wanted it. Both are safe to let go of twice.
            KeyboardInput.Typed -= OnTyped;
            KeyboardInput.Pressed -= OnPressed;
            KeyboardInput.Release();
            if (m_Keyboard != null)
            {
                m_Keyboard.Typed -= OnTyped;
                m_Keyboard.Pressed -= OnPressed;
                m_Keyboard.Dictate -= OnDictate;
                m_Keyboard.Close();
            }
            // Never leave the microphone running behind a closed browser.
            if (Dictation.Listening)
                Dictation.Stop();
            m_Typed = null;
            m_Heard = null;
            m_SpokenOnto = null;

            if (m_Store != null && m_Store.Dirty)
                m_Store.Save(BrowserStore.DefaultPath);
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
            // arrived upside down. PageV reads this same flag to work out where on the page a
            // point on the quad is -- as the opposite flip, not the same one, which is the thing
            // that was wrong: the picture needs turning over and the gaze then needs turning
            // back, and doing both the same way mirrored every click vertically.
            if (m_FlipV)
            {
                m_Material.mainTextureScale = new Vector2(1f, -1f);
                m_Material.mainTextureOffset = new Vector2(0f, 1f);
            }
            m_Renderer.sharedMaterial = m_Material;
            // A screen tap clicks the page where the gaze is, as a pinch does (TryBeginPinch): the
            // quad's collider is what the gaze pointer hits.
            m_Window.AddComponent<GazeClick>().Clicked += ClickAtGaze;
            m_Width = k_Widths[m_WidthStep];
            ApplySize();
            BuildAddressBar();
            BuildTabBar();
            BuildControls();
            if (m_Tabs.Count == 0)
                m_Tabs.Add(new Tab { Url = StartPage, Title = "Start" });
            if (m_Tab < 0)
                m_Tab = 0;
            RebuildTabs();
            Place();
        }

        string StartPage => "file://" + Path.Combine(Application.streamingAssetsPath, m_HomePage);
        // How the store names the start page, since its path is the install's.
        const string k_StartPageName = "afterglow://start";
        // The Keychain account a password with no username is kept under.
        const string k_PasswordOnlyAccount = "(password only)";

        void ClickAtGaze()
        {
            if (m_Placing)
            {
                EndPlacing();
                return;
            }
            if (!WebBrowser.IsOpen || m_Immersive || !TryGazePoint(out var u, out var v))
                return;
            WebBrowser.ClickAt(u, v);
            Debug.Log($"[WebXR] Tap at {u:F2}, {v:F2} on the page");
        }

        // The tracked hands as the page takes them (WebBrowser.PushHands): count, then per hand its
        // handedness, whether it pinches and its 21 joints in WebXR's space, which is Unity's
        // with z the other way. Pure: the joints are read from the hands as given.
        public static int HandsToPage(IReadOnlyList<TrackedHand> hands, Func<TrackedHand, bool> pinching,
            Func<TrackedHand, bool> isRight, float[] values)
        {
            var count = 0;
            foreach (var hand in hands)
            {
                if (!hand.isTracking || count >= HandTracker.MaxHands)
                    continue;
                var at = 1 + count * WebBrowser.FloatsPerHand;
                // The side as the feed settles it, so a reading that wavers doesn't swap the page's controllers.
                values[at] = isRight(hand) ? 1f : 0f;
                values[at + 1] = pinching(hand) ? 1f : 0f;
                for (var i = 0; i < HandGeometry.JointCount; i++)
                {
                    var joint = hand.joints[i];
                    values[at + 2 + i * 3] = joint.x;
                    values[at + 3 + i * 3] = joint.y;
                    values[at + 4 + i * 3] = -joint.z;
                }
                count++;
            }
            values[0] = count;
            return count;
        }

        // The address, with the two ways into it beside it: the keys and the microphone. It is
        // also the only thing that says where the typing is going, so it is never a mystery
        // whether a keystroke reached the page or the bar.
        void BuildAddressBar()
        {
            if (m_Address != null)
                return;
            const float width = 800f, height = 72f;
            m_Address = M3.Canvas("Web Address", transform, new Vector2(width, height),
                M3Theme.k_OverlayDistance, M3Theme.SurfaceContainerHigh, M3Theme.k_ShapeFull);
            m_Address.gameObject.AddComponent<GazeCanvas>();
            // Back, forward and reload on the left, as a browser has them.
            M3.IconButton("Back", m_Address, "chevron_left", M3Button.Variant.Text,
                new Vector2(-width / 2f + 36f, 0f), WebBrowser.GoBack, 48f);
            M3.IconButton("Forward", m_Address, "chevron_right", M3Button.Variant.Text,
                new Vector2(-width / 2f + 84f, 0f), WebBrowser.GoForward, 48f);
            M3.IconButton("Reload", m_Address, "refresh", M3Button.Variant.Text,
                new Vector2(-width / 2f + 132f, 0f), WebBrowser.Reload, 48f);
            M3.IconButton("Keys", m_Address, "keyboard", M3Button.Variant.Tonal,
                new Vector2(width / 2f - 44f, 0f), ToggleKeys);
            M3.IconButton("Dictate", m_Address, "mic", M3Button.Variant.Tonal,
                new Vector2(width / 2f - 104f, 0f), OnDictate);
            // The star keeps the page as a bookmark, filled while it is one.
            m_Star = M3.IconButton("Bookmark", m_Address, "star_border", M3Button.Variant.Text,
                new Vector2(width / 2f - 164f, 0f), ToggleBookmark, 48f);
            // The field: a lighter pill with the address, which typing and dictation fill.
            var fieldLeft = -width / 2f + 164f;
            var fieldRight = width / 2f - 196f;
            var field = M3.Surface("Field", m_Address, new Vector2((fieldLeft + fieldRight) / 2f, 0f),
                new Vector2(fieldRight - fieldLeft, height - 20f), M3Theme.SurfaceContainerHighest, M3Theme.k_ShapeFull);
            m_AddressText = M3.Text("Address", field.rectTransform, "", M3Theme.Type.BodyLarge,
                new Vector2(8f, 0f), new Vector2(fieldRight - fieldLeft - 32f, height - 20f),
                M3Theme.OnSurface, TextAlignmentOptions.Left);
            m_AddressText.textWrappingMode = TextWrappingModes.NoWrap;
            m_AddressText.overflowMode = TextOverflowModes.Ellipsis;
        }

        // The tabs, above the address: a chip per tab with the page's title, the current one
        // selected, then New and Close for tabs.
        // A finger held on the screen for k_EndPressSeconds ends the session.
        const float k_TapSeconds = 0.4f;

        void UpdateLongPress()
        {
            var touch = UnityEngine.InputSystem.Touchscreen.current;
            var pressed = touch != null && touch.primaryTouch.press.isPressed;
            if (!pressed)
            {
                // A short press that ended is a tap: a WebXR select, as a pinch is. A viewer's
                // button is exactly that tap.
                if (m_PressedSince >= 0f && !m_EndRequested && Time.unscaledTime - m_PressedSince < k_TapSeconds)
                {
                    WebBrowser.Select();
                    Debug.Log("[WebXR] Tap: select to the page");
                }
                m_PressedSince = -1f;
                m_EndRequested = false;
                return;
            }
            if (m_PressedSince < 0f)
                m_PressedSince = Time.unscaledTime;
            if (!m_EndRequested && Time.unscaledTime - m_PressedSince >= k_EndPressSeconds)
            {
                m_EndRequested = true;
                Debug.Log("[WebXR] Long press: ending the session");
                WebBrowser.EndSession();
            }
        }

        // The login prompt, built once and shown when there is something to ask.
        void BuildPrompt()
        {
            if (m_Prompt != null)
                return;
            const float width = 800f, height = 64f;
            m_Prompt = M3.Canvas("Web Login", transform, new Vector2(width, height),
                M3Theme.k_OverlayDistance, M3Theme.SurfaceContainerHighest, M3Theme.k_ShapeFull);
            m_Prompt.gameObject.AddComponent<GazeCanvas>();
            m_PromptText = M3.Text("Question", m_Prompt, "", M3Theme.Type.BodyLarge, new Vector2(-96f, 0f), new Vector2(width - 256f, height),
                M3Theme.OnSurface, TextAlignmentOptions.Left);
            m_PromptText.textWrappingMode = TextWrappingModes.NoWrap;
            m_PromptText.overflowMode = TextOverflowModes.Ellipsis;
            m_PromptYes = M3.Button("Yes", m_Prompt, "Save", M3Button.Variant.Filled, new Vector2(width / 2f - 148f, 0f), AnswerPrompt, null, 112f);
            M3.IconButton("Not now", m_Prompt, "close", M3Button.Variant.Text, new Vector2(width / 2f - 56f, 0f), HidePrompt, 48f);
            m_Prompt.gameObject.SetActive(false);
        }

        void ShowPrompt(string text, string yes, bool save, string host, string user, string secret)
        {
            BuildPrompt();
            m_PromptText.text = text;
            m_PromptYes.Text = yes;
            m_PromptIsSave = save;
            m_PromptHost = host;
            m_PromptUser = user;
            m_PromptSecret = secret;
            m_Prompt.gameObject.SetActive(true);
            Place();
        }

        void HidePrompt()
        {
            if (m_Prompt != null)
                m_Prompt.gameObject.SetActive(false);
            m_PromptSecret = null;
        }

        void AnswerPrompt()
        {
            if (m_PromptIsSave)
            {
                var ok = Keychain.Store(m_PromptHost, m_PromptUser, m_PromptSecret);
                Debug.Log($"[WebXR] Password for {m_PromptHost} ({m_PromptUser}) {(ok ? "saved in the Keychain" : "could not be saved")}");
            }
            else if (Keychain.TryLoad(m_PromptHost, m_PromptUser, out var secret))
            {
                WebBrowser.Fill(m_PromptUser == k_PasswordOnlyAccount ? "" : m_PromptUser, secret);
                Debug.Log($"[WebXR] Filled the saved login for {m_PromptHost} ({m_PromptUser})");
            }
            HidePrompt();
        }

        // What the page says about logins: a submitted one to offer to keep, a form to offer a
        // saved login for. The password is held only until the prompt is answered or dismissed.
        void UpdateLogins()
        {
            if (!Keychain.Supported)
                return;
            if (WebBrowser.TryTakeCredential(out var host, out var user, out var password))
            {
                // A site that asks for a password alone (no username) keeps it under a name of
                // the app's own; the fill then puts back only the password.
                var passwordOnly = string.IsNullOrEmpty(user);
                var account = passwordOnly ? k_PasswordOnlyAccount : user;
                var who = passwordOnly ? "" : $" ({user})";
                if (Keychain.TryLoad(host, account, out var known) && known == password)
                    Debug.Log($"[WebXR] The login for {host}{who} is already saved");
                else
                    ShowPrompt($"Save the password for {host}{who}?", "Save", true, host, account, password);
            }
            if (WebBrowser.TryTakeLoginHost(out var loginHost))
            {
                var accounts = Keychain.Accounts(loginHost);
                if (accounts.Length > 0)
                {
                    var who = accounts[0] == k_PasswordOnlyAccount ? "" : $" ({accounts[0]})";
                    ShowPrompt($"Fill the saved {(who.Length == 0 ? "password" : "login")} for {loginHost}{who}?", "Fill", false, loginHost, accounts[0], null);
                }
            }
        }

        void BuildTabBar()
        {
            if (m_TabBar != null)
                return;
            m_TabBar = M3.Canvas("Web Tabs", transform, new Vector2(800f, 56f),
                M3Theme.k_OverlayDistance, M3Theme.SurfaceContainer, M3Theme.k_ShapeFull);
            m_TabBar.gameObject.AddComponent<GazeCanvas>();
        }

        void RebuildTabs()
        {
            if (m_TabBar == null)
                return;
            for (var i = m_TabBar.childCount - 1; i >= 0; i--)
                Destroy(m_TabBar.GetChild(i).gameObject);
            const float width = 800f, chip = 108f, gap = 6f;
            var x = -width / 2f + 16f + chip / 2f;
            for (var i = 0; i < m_Tabs.Count; i++)
            {
                var index = i;
                var button = M3.Button($"Tab {i}", m_TabBar, TabLabel(m_Tabs[i].Title, m_Tabs[i].Url), M3Button.Variant.Tonal,
                    new Vector2(x, 0f), () => SelectTab(index), null, chip);
                button.Selected = i == m_Tab;
                x += chip + gap;
            }
            M3.IconButton("New Tab", m_TabBar, "add", M3Button.Variant.Text, new Vector2(width / 2f - 84f, 0f), NewTab, 44f)
                .Interactable = m_Tabs.Count < k_MaxTabs;
            M3.IconButton("Close Tab", m_TabBar, "close", M3Button.Variant.Text, new Vector2(width / 2f - 36f, 0f), CloseTab, 44f);
        }

        // What a tab's chip says: the page's title, else its host, cut to fit the chip.
        public static string TabLabel(string title, string url, int limit = 12)
        {
            var text = !string.IsNullOrWhiteSpace(title) ? title.Trim() : ShortenUrl(url, 24);
            if (string.IsNullOrEmpty(text))
                text = "New tab";
            var slash = text.IndexOf('/');
            if (string.IsNullOrWhiteSpace(title) && slash > 0)
                text = text.Substring(0, slash);
            return text.Length <= limit ? text : text.Substring(0, limit - 1) + "…";
        }

        void NewTab()
        {
            if (m_Tabs.Count >= k_MaxTabs)
                return;
            m_Tabs.Add(new Tab { Url = StartPage, Title = "Start" });
            SelectTab(m_Tabs.Count - 1);
            Debug.Log($"[WebXR] New tab, {m_Tabs.Count} open");
        }

        // The tabs as they are now, for the store; written out with the next save.
        void RememberTabs()
        {
            if (m_Store == null)
                return;
            var tabs = new List<(string url, string title)>();
            foreach (var tab in m_Tabs)
                tabs.Add(IsStartPage(tab.Url) ? (k_StartPageName, "Start") : (tab.Url, tab.Title));
            m_Store.RememberTabs(tabs, m_Tab);
        }

        // Keeps or drops the bookmark for the page showing, and redraws the start page if that
        // is what's showing.
        void ToggleBookmark()
        {
            if (m_Store == null || !BrowserStore.IsRememberable(m_UrlShown))
            {
                Debug.Log("[WebXR] Nothing to bookmark here");
                return;
            }
            var kept = m_Store.ToggleBookmark(m_UrlShown, WebBrowser.CurrentTitle, BrowserStore.Now);
            Debug.Log($"[WebXR] Bookmark {(kept ? "kept" : "dropped")}: {ShortenUrl(m_UrlShown)}");
            UpdateStar();
        }

        void UpdateStar()
        {
            if (m_Star == null)
                return;
            var kept = m_Store != null && m_Store.IsBookmarked(m_UrlShown);
            if (kept != m_StarFilled)
            {
                m_StarFilled = kept;
                m_Star.Icon = kept ? "star" : "star_border";
            }
            m_Star.Interactable = BrowserStore.IsRememberable(m_UrlShown);
        }

        // Hands the start page its bookmarks and recent pages.
        void FeedStartPage()
        {
            if (m_Store == null)
                return;
            Debug.Log($"[WebXR] Start page given {m_Store.Bookmarks.Count} bookmarks and {Mathf.Min(m_Store.History.Count, BrowserStore.k_StartPageHistory)} recent pages");
            WebBrowser.RunScript("window.__afterglowLists&&window.__afterglowLists(" + m_Store.StartPageJson(BrowserStore.Now) + ")");
        }

        bool IsStartPage(string url) => !string.IsNullOrEmpty(url) && url.StartsWith("file://", System.StringComparison.Ordinal);

        void SelectTab(int index)
        {
            if (index < 0 || index >= m_Tabs.Count)
                return;
            if (index != m_Tab)
            {
                m_Tab = index;
                m_Typed = null;
                WebBrowser.LoadUrl(m_Tabs[index].Url);
                Debug.Log($"[WebXR] Tab {index + 1}: {ShortenUrl(m_Tabs[index].Url)}");
            }
            RebuildTabs();
            RememberTabs();
        }

        void CloseTab()
        {
            if (m_Tabs.Count <= 1)
            {
                Close();
                return;
            }
            m_Tabs.RemoveAt(m_Tab);
            var next = Mathf.Clamp(m_Tab, 0, m_Tabs.Count - 1);
            m_Tab = -1;
            SelectTab(next);
            Debug.Log($"[WebXR] Tab closed, {m_Tabs.Count} open");
        }

        // The start page, in this tab.
        void GoStart()
        {
            m_Typed = null;
            WebBrowser.LoadUrl(StartPage);
        }

        void TearDownWindow()
        {
            if (m_Bar != null)
                Destroy(m_Bar.gameObject);
            m_Bar = null;
            if (m_Address != null)
                Destroy(m_Address.gameObject);
            m_Address = null;
            m_AddressText = null;
            m_Star = null;
            m_StarFilled = false;
            if (m_Prompt != null)
                Destroy(m_Prompt.gameObject);
            m_Prompt = null;
            m_PromptSecret = null;
            if (m_TabBar != null)
                Destroy(m_TabBar.gameObject);
            m_TabBar = null;
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
            Layout();
        }

        // Placing: the window follows the gaze wherever it points, up and down included, until a
        // pinch or a tap sets it down. The one-shot Place put the window at the level gaze the
        // moment its button was pressed, and that button sits just under the window, so the
        // window could never go up or down and barely moved sideways.
        void BeginPlacing()
        {
            if (m_Window == null || m_Fusion == null)
                return;
            m_Placing = !m_Placing;
            Debug.Log(m_Placing ? "[WebXR] Placing: the window follows the gaze; pinch or tap to set it down" : "[WebXR] Placed");
        }

        void EndPlacing()
        {
            if (!m_Placing)
                return;
            m_Placing = false;
            Debug.Log($"[WebXR] Placed at {m_Window.transform.position}");
        }

        void FollowGaze()
        {
            var head = m_Fusion.transform;
            var forward = head.forward;
            if (forward.sqrMagnitude < 1e-4f)
                return;
            forward.Normalize();
            m_Window.transform.position = head.position + forward * m_Distance;
            // Tipped with the gaze so the page faces the head wherever it is put, upright left to right.
            m_Window.transform.rotation = Quaternion.LookRotation(forward, Vector3.up);
            Layout();
        }

        // The chrome around the window: the tabs over the address over the page, the toolbar and
        // the keys under it, wherever the window is.
        void Layout()
        {
            // Stacked under the window, facing the same way, far enough down to clear the page's
            // bottom edge at whatever size it is now: the address, then the toolbar, then the keys.
            var pageHeight = m_Width * WebBrowser.WindowHeight / WebBrowser.WindowWidth;
            var up = m_Window.transform.up;
            var above = m_Window.transform.position + up * (pageHeight / 2f);
            var below = m_Window.transform.position - up * (pageHeight / 2f);
            // The chrome a browser has at the top: the tabs over the address over the page; what
            // the window itself does, below it.
            if (m_Address != null)
            {
                m_Address.position = above + up * 0.07f;
                m_Address.rotation = m_Window.transform.rotation;
            }
            if (m_Prompt != null)
            {
                m_Prompt.position = above + up * 0.27f;
                m_Prompt.rotation = m_Window.transform.rotation;
            }
            if (m_TabBar != null)
            {
                m_TabBar.position = above + up * 0.17f;
                m_TabBar.rotation = m_Window.transform.rotation;
            }
            if (m_Bar != null)
            {
                m_Bar.position = below - up * 0.09f;
                m_Bar.rotation = m_Window.transform.rotation;
            }
            PlaceKeyboard();
        }

        // Lower than the toolbar and nearer, tipped to face the head rather than standing
        // upright, because this one is looked down at the way a real keyboard is. Pointing its
        // back at the head is what faces it forward -- the window is oriented the same way.
        //
        // Separate from Place() because the keys can be shown and hidden without the page moving.
        void PlaceKeyboard()
        {
            if (m_Window == null || m_Fusion == null || m_Keyboard == null || m_Keyboard.Panel == null)
                return;
            var pageHeight = m_Width * WebBrowser.WindowHeight / WebBrowser.WindowWidth;
            var panel = m_Keyboard.Panel;
            panel.position = m_Window.transform.position
                             - m_Window.transform.up * (pageHeight / 2f + 0.52f)
                             - m_Window.transform.forward * 0.25f;
            var away = panel.position - m_Fusion.transform.position;
            if (away.sqrMagnitude > 1e-4f)
                panel.rotation = Quaternion.LookRotation(away.normalized, Vector3.up);
        }

        void Update()
        {
            if (!WebBrowser.IsOpen)
                return;
            if (m_Placing && !m_Immersive)
                FollowGaze();
            // The keys come up when the page focuses a field, so typing is a glance away without
            // reaching for the keys button; they stay until closed, since focus comes and goes.
            var focused = WebBrowser.TextFocused;
            if (focused && !m_WasTextFocused && !m_Immersive && m_Keyboard != null && !m_Keyboard.IsOpen)
            {
                m_Keyboard.Open();
                PlaceKeyboard();
                Debug.Log("[WebXR] The page focused a field; the keys are up");
            }
            m_WasTextFocused = focused;

            if (m_Fusion != null)
            {
                var head = m_Fusion.transform;
                WebBrowser.PushPose(head.position, head.rotation);
            }
            if (m_Immersive && m_Tracker != null)
            {
                var count = HandsToPage(m_Tracker.Hands, hand => m_Feed != null && m_Feed.IsPinchingWith(hand),
                    hand => m_Feed != null && m_Feed.TryGetSide(hand, out var right) ? right : hand.handednessScore >= 0.5f, m_HandValues);
                if (count > 0 || m_PushedHands > 0)
                    WebBrowser.PushHands(m_HandValues, 1 + count * WebBrowser.FloatsPerHand);
                m_PushedHands = count;
                // Said when it changes: whether the page is told a hand pinches, and how far
                // apart its fingertips are, which is what a page that reads its own pinch sees.
                var pinches = 0;
                for (var h = 0; h < count; h++)
                    if (m_HandValues[1 + h * WebBrowser.FloatsPerHand + 1] > 0.5f) pinches |= 1 << h;
                if (pinches != m_PushedPinches)
                {
                    m_PushedPinches = pinches;
                    var tips = "";
                    for (var h = 0; h < count; h++)
                    {
                        var at = 1 + h * WebBrowser.FloatsPerHand + 2;
                        var thumb = new Vector3(m_HandValues[at + 4 * 3], m_HandValues[at + 4 * 3 + 1], m_HandValues[at + 4 * 3 + 2]);
                        var index = new Vector3(m_HandValues[at + 8 * 3], m_HandValues[at + 8 * 3 + 1], m_HandValues[at + 8 * 3 + 2]);
                        tips += $"{(h > 0 ? ", " : "")}{(m_HandValues[1 + h * WebBrowser.FloatsPerHand] > 0.5f ? "right" : "left")} {(((pinches >> h) & 1) != 0 ? "pinching" : "open")}, tips {Vector3.Distance(thumb, index) * 100f:F1} cm apart";
                    }
                    Debug.Log($"[WebXR] Hands to the page: {tips}");
                }
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
                    if (m_Address != null)
                        m_Address.gameObject.SetActive(false);
                    if (m_TabBar != null)
                        m_TabBar.gameObject.SetActive(false);
                    HidePrompt();
                    Debug.Log("[WebXR] Immersive session: the page has the screen");
                    break;
                case WebBrowser.Event.SessionEnd:
                    m_Immersive = false;
                    WebBrowser.SetWindowed(true);
                    if (m_Window != null)
                        m_Window.SetActive(true);
                    if (m_Bar != null)
                        m_Bar.gameObject.SetActive(true);
                    if (m_Address != null)
                        m_Address.gameObject.SetActive(true);
                    if (m_TabBar != null)
                        m_TabBar.gameObject.SetActive(true);
                    Place();
                    Debug.Log("[WebXR] Session ended: back to a window in the scene");
                    break;
                case WebBrowser.Event.Close:
                    Close();
                    return;
                case WebBrowser.Event.StartPage:
                    FeedStartPage();
                    break;
                case WebBrowser.Event.ClearHistory:
                    if (m_Store != null)
                    {
                        m_Store.ClearHistory();
                        Debug.Log("[WebXR] History cleared");
                        FeedStartPage();
                    }
                    break;
            }

            if (m_Immersive)
            {
                UpdateLongPress();
                return;
            }

            if (WebBrowser.TryUpdateTexture(ref m_Page) && m_Material != null)
                m_Material.mainTexture = m_Page;

            // Binds a Bluetooth keyboard as one appears, which is how it will be paired: with the
            // phone already in the viewer.
            KeyboardInput.Poll();
            UpdateDictation();
            UpdateAddress();
            UpdateLogins();

            var aimed = TryGazePoint(out var u, out var v);
            ShowAim(aimed, u, v);
            if (aimed)
                GazeScroll(u, v);
            // And from a controller's stick, which is steadier than holding a gaze at an edge.
            // At the gaze point, so a stick scrolls whatever is being read rather than only the
            // page as a whole; the middle of the window if the gaze is off it.
            // Scroll already carries its own speed in page pixels a second, so this only needs
            // the frame's share of it.
            var stick = GamepadInput.Scroll;
            if (stick.sqrMagnitude > 0f)
                WebBrowser.ScrollAt(aimed ? u : 0.5f, aimed ? v : 0.5f,
                                    stick.x * Time.unscaledDeltaTime,
                                    -stick.y * Time.unscaledDeltaTime);
        }

        // Puts a crosshair on the page where the gaze is, with whatever a pinch would press
        // outlined around it. At the capture's own rate, since that is how often it can be seen.
        void ShowAim(bool aimed, float u, float v)
        {
            if (Time.unscaledTime - m_LastAim < 1f / 12f)
                return;
            m_LastAim = Time.unscaledTime;
            // Off the page: park it in a corner rather than leave it where the gaze last was,
            // which would read as a crosshair that has stuck.
            WebBrowser.HoverAt(aimed ? u : -1f, aimed ? v : -1f);
        }

        void ToggleKeys()
        {
            if (m_Keyboard == null)
                return;
            m_Keyboard.Toggle();
            // The panel is built the first time it opens, so this is when it gets put somewhere.
            // Only the panel: Place() moves the window to wherever the head is pointing, and
            // pressing a button on the toolbar is not a request to move the page you are reading.
            if (m_Keyboard.IsOpen)
                PlaceKeyboard();
        }

        // Typing goes to the page's own field whenever it has one focused, and to the address bar
        // when it does not. Which it is is the page's business rather than a mode to be set: click
        // a search box and type, or click nothing and type where you want to go.
        void OnTyped(string text)
        {
            if (!WebBrowser.IsOpen || m_Immersive)
                return;
            if (WebBrowser.TextFocused)
            {
                WebBrowser.Type(text);
                return;
            }
            m_Typed = (m_Typed ?? "") + text;
        }

        void OnPressed(string key)
        {
            if (!WebBrowser.IsOpen || m_Immersive)
                return;
            var toPage = WebBrowser.TextFocused;
            switch (key)
            {
                case "Escape":
                    // Back out one layer at a time: what was typed, then the keys themselves.
                    if (m_Typed != null)
                        m_Typed = null;
                    else if (m_Keyboard != null)
                        m_Keyboard.Close();
                    break;
                case "Enter":
                    if (toPage)
                        WebBrowser.Key("Enter");
                    else
                        Go();
                    break;
                case "Clear":
                    if (toPage)
                        WebBrowser.Key("Clear");
                    else
                        m_Typed = "";
                    break;
                default:
                    if (toPage)
                        WebBrowser.Key("Backspace");
                    else if (!string.IsNullOrEmpty(m_Typed))
                        m_Typed = m_Typed.Substring(0, m_Typed.Length - 1);
                    break;
            }
        }

        void Go()
        {
            var address = WebBrowser.NormalizeAddress(m_Typed);
            if (address == null)
                return;
            Debug.Log($"[WebXR] Going to {address}");
            WebBrowser.LoadUrl(address);
            m_Typed = null;
            if (m_Keyboard != null)
                m_Keyboard.Close();
        }

        // Push to talk, as a toggle: pressing it again stops, and a phrase that ends on its own
        // stops too. Holding a gaze on a button is not a thing anyone can do comfortably, so the
        // press-and-hold a microphone usually wants is a press-and-press here.
        void OnDictate()
        {
            if (!WebBrowser.IsOpen || m_Immersive)
                return;
            if (Dictation.Listening)
            {
                Dictation.Stop();
                return;
            }
            if (!Dictation.Supported)
            {
                Debug.Log($"[Speech] {Dictation.Describe(Dictation.State.Unavailable)}");
                return;
            }
            // What was already in the address bar is kept and spoken onto the end of; a field on
            // the page is appended to by the page itself, at its caret.
            m_SpokenOnto = WebBrowser.TextFocused ? null : m_Typed ?? "";
            Dictation.Start();
        }

        void UpdateDictation()
        {
            if (Dictation.Listening)
            {
                // Shown filling in as it is spoken, but not committed: a phrase is only worth
                // acting on once it has finished. Ten times a second, which reads as live and is
                // not a string built out of Objective-C on every frame.
                if (Time.unscaledTime >= m_NextHeardPoll)
                {
                    m_NextHeardPoll = Time.unscaledTime + 0.1f;
                    m_Heard = Dictation.Text;
                }
                return;
            }
            if (!Dictation.TakeFinished())
                return;
            var heard = Dictation.Text;
            m_Heard = null;
            if (string.IsNullOrWhiteSpace(heard))
                return;
            Debug.Log($"[Speech] Heard \"{heard}\"");
            if (m_SpokenOnto == null)
                WebBrowser.Type(heard);
            else
                m_Typed = m_SpokenOnto.Length > 0 ? m_SpokenOnto + " " + heard : heard;
            m_SpokenOnto = null;
        }

        // The bar shows what is being heard, else what is being typed, else where the page is.
        void UpdateAddress()
        {
            if (m_AddressText == null)
                return;
            if (Time.unscaledTime >= m_NextUrlPoll)
            {
                // Twice a second: it crosses into Objective-C and the address rarely changes.
                m_NextUrlPoll = Time.unscaledTime + 0.5f;
                m_UrlShown = WebBrowser.CurrentUrl;
                if (m_Tab >= 0 && m_Tab < m_Tabs.Count && !string.IsNullOrEmpty(m_UrlShown))
                {
                    var tab = m_Tabs[m_Tab];
                    var title = WebBrowser.CurrentTitle;
                    if (tab.Url != m_UrlShown || tab.Title != title)
                    {
                        tab.Url = m_UrlShown;
                        tab.Title = title;
                        RebuildTabs();
                        RememberTabs();
                        if (m_Store != null && m_Store.Visit(m_UrlShown, title, BrowserStore.Now))
                            Debug.Log($"[WebXR] Remembered {ShortenUrl(m_UrlShown)}");
                    }
                }
                var onStart = IsStartPage(m_UrlShown);
                if (onStart && !m_OnStartPage)
                {
                    FeedStartPage();
                    m_FeedStartPageAt = Time.unscaledTime + 1f;
                }
                m_OnStartPage = onStart;
                UpdateStar();
                // The store is written a little after it changes, not on every visit.
                if (m_Store != null && m_Store.Dirty && Time.unscaledTime >= m_NextStoreSave)
                {
                    m_NextStoreSave = Time.unscaledTime + 5f;
                    m_Store.Save(BrowserStore.DefaultPath);
                }
            }
            if (m_FeedStartPageAt > 0f && Time.unscaledTime >= m_FeedStartPageAt)
            {
                m_FeedStartPageAt = -1f;
                if (m_OnStartPage)
                    FeedStartPage();
            }
            m_AddressText.text = m_Heard != null ? m_Heard + " ..."
                               : m_Typed != null ? m_Typed + "|"
                               : ShortenUrl(m_UrlShown);
            if (m_Keyboard != null && m_Keyboard.IsOpen)
                m_Keyboard.SetCaption(Caption());
        }

        string Caption()
        {
            var state = Dictation.Current;
            if (state != Dictation.State.Idle)
                return Dictation.Describe(state);
            if (WebBrowser.TextFocused)
                return "Typing into the page";
            return KeyboardInput.Present
                ? "Typing an address, and a keyboard is connected"
                : "Typing an address";
        }

        // The address as it is worth showing. A bar in a viewer is read at a glance through a
        // lens, so the scheme and a trailing slash are noise; a long one is cut in the middle,
        // since the host is at the front and the page's own name is at the end and both matter.
        public static string ShortenUrl(string url, int limit = 56)
        {
            if (string.IsNullOrEmpty(url))
                return "";
            var text = url;
            foreach (var prefix in new[] { "https://", "http://", "file://" })
            {
                if (!text.StartsWith(prefix, StringComparison.Ordinal))
                    continue;
                text = text.Substring(prefix.Length);
                break;
            }
            if (text.StartsWith("www.", StringComparison.Ordinal))
                text = text.Substring(4);
            if (text.Length > 1 && text.EndsWith("/", StringComparison.Ordinal))
                text = text.Substring(0, text.Length - 1);
            if (text.Length <= limit)
                return text;
            var keepEnd = limit / 3;
            var keepStart = limit - keepEnd - 1;
            return text.Substring(0, keepStart) + "…" + text.Substring(text.Length - keepEnd);
        }

        // Looking near the window's top or bottom edge scrolls the page, so reading needs no
        // hands at all -- which matters in a viewer, where a pinch is the only other input and
        // holding one to scroll is tiring.
        void GazeScroll(float u, float v)
        {
            var from = v < m_ScrollEdge ? (v - m_ScrollEdge) / m_ScrollEdge
                     : v > 1f - m_ScrollEdge ? (v - (1f - m_ScrollEdge)) / m_ScrollEdge
                     : 0f;
            if (Mathf.Approximately(from, 0f))
                return;
            // v is measured down the page, so looking low scrolls down.
            WebBrowser.ScrollAt(u, v, 0f, from * m_ScrollSpeed * Time.unscaledDeltaTime);
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
            v = PageV(local.y, m_FlipV);
            return u >= 0f && u <= 1f && v >= 0f && v <= 1f;
        }

        // How far down the page a point on the quad is, from a local y of +0.5 at the top to
        // -0.5 at the bottom. Pure so it can be checked, because getting it backwards is not
        // visible -- it mirrors every click vertically, which on a page full of links looks like
        // a browser that works erratically rather than one aiming at the wrong place.
        //
        // The capture writes the page's top row first, and Unity's textures start at the bottom,
        // so the stored picture is upside down and the material flips it: m_FlipV. That flip is
        // what decides this. With it, quad v maps to texture 1-v, and texture v counts down the
        // page from its top -- so the page fraction is 1 - (localY + 0.5). Without it, the
        // picture would be upside down and the page fraction would be localY + 0.5 to match.
        public static float PageV(float localY, bool flipV) =>
            flipV ? 0.5f - localY : localY + 0.5f;

        // A pinch clicks wherever the gaze is on the page.
        public bool TryBeginPinch(GameObject gazeTarget, PinchSource source)
        {
            if (!WebBrowser.IsOpen)
                return false;
            // A pinch while placing sets the window down and does nothing else.
            if (m_Placing)
            {
                EndPlacing();
                return true;
            }
            // During an immersive session the page has no window to click: a pinch is a WebXR
            // select. With a hand tracked, the page already gets it on that hand's input source
            // (HandsToPage carries the pinch); otherwise it goes on the gaze source.
            if (m_Immersive)
            {
                if (m_Tracker == null || m_Tracker.TrackedCount == 0)
                {
                    WebBrowser.Select();
                    Debug.Log("[WebXR] Pinch: select to the page on the gaze source");
                }
                return true;
            }
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
                ("home", "Start page", GoStart),
                ("aspect_ratio", "Size", CycleSize),
                ("open_with", "Place", BeginPlacing),
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
                // The start page apart from what the window does.
                groups[i] = i < 1 ? 0 : 1;
            }
            m_Bar.gameObject.AddComponent<M3Toolbar>()
                .Initialize(items, groups, new Image[2], new RectTransform[0], width, padding, 0f);
        }

        public void EndPinch() { }
    }
}
