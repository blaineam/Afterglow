using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;

namespace Afterglow.Demos
{
    // What the browser remembers between sessions: bookmarks, the pages visited, and the tabs
    // that were open, in one JSON file in the app's own folder. Pure apart from the file: every
    // rule here takes its inputs and is tested without a browser. The start page draws the
    // bookmarks and the recent pages from StartPageJson, and the star in the address bar asks
    // IsBookmarked. Nothing leaves the phone.
    [Serializable]
    public class BrowserStore
    {
        [Serializable]
        public class Page
        {
            public string Url;
            public string Title;
            // Unix seconds of the last visit (or of the bookmarking).
            public long When;
            public int Visits;
        }

        [Serializable]
        public class Tab
        {
            public string Url;
            public string Title;
        }

        public const int k_HistoryLimit = 200;
        public const int k_StartPageHistory = 12;
        public const string FileName = "browser.json";

        public List<Page> Bookmarks = new();
        // Newest first.
        public List<Page> History = new();
        public List<Tab> Tabs = new();
        public int SelectedTab;

        // Something changed since the last Save, so the file wants writing.
        [NonSerialized] public bool Dirty;

        public static string DefaultPath => Path.Combine(Application.persistentDataPath, FileName);

        // What's worth remembering: a page on the web. The start page and other local files, and
        // nothing at all, aren't.
        public static bool IsRememberable(string url) =>
            !string.IsNullOrWhiteSpace(url) &&
            (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || url.StartsWith("http://", StringComparison.OrdinalIgnoreCase));

        // A page was shown: it goes to the top of the history, counted, with its latest title.
        // Returns whether anything changed.
        public bool Visit(string url, string title, long now)
        {
            if (!IsRememberable(url))
                return false;
            var index = History.FindIndex(page => page.Url == url);
            Page page;
            if (index >= 0)
            {
                page = History[index];
                // The same page again, moments later (a redirect, a reload, the title arriving):
                // not a new visit, but the title is taken.
                var again = now - page.When < 60;
                History.RemoveAt(index);
                if (!again)
                    page.Visits++;
                else if (string.IsNullOrWhiteSpace(title) || page.Title == title)
                {
                    History.Insert(0, page);
                    return false;
                }
            }
            else
                page = new Page { Url = url, Visits = 1 };
            if (!string.IsNullOrWhiteSpace(title))
                page.Title = title.Trim();
            page.When = now;
            History.Insert(0, page);
            while (History.Count > k_HistoryLimit)
                History.RemoveAt(History.Count - 1);
            Dirty = true;
            return true;
        }

        public bool IsBookmarked(string url) => IsRememberable(url) && Bookmarks.Exists(page => page.Url == url);

        // Bookmarks the page, or takes the bookmark away if it had one. Returns whether it has
        // one now.
        public bool ToggleBookmark(string url, string title, long now)
        {
            if (!IsRememberable(url))
                return false;
            var index = Bookmarks.FindIndex(page => page.Url == url);
            Dirty = true;
            if (index >= 0)
            {
                Bookmarks.RemoveAt(index);
                return false;
            }
            Bookmarks.Add(new Page { Url = url, Title = string.IsNullOrWhiteSpace(title) ? null : title.Trim(), When = now, Visits = 1 });
            return true;
        }

        public void ClearHistory()
        {
            if (History.Count == 0)
                return;
            History.Clear();
            Dirty = true;
        }

        // The open tabs, so the browser comes back as it was left.
        public void RememberTabs(IEnumerable<(string url, string title)> tabs, int selected)
        {
            Tabs.Clear();
            foreach (var (url, title) in tabs)
                Tabs.Add(new Tab { Url = url, Title = title });
            SelectedTab = selected;
            Dirty = true;
        }

        // What a page is called in a list: its title, else its host.
        public static string Label(Page page) =>
            !string.IsNullOrWhiteSpace(page.Title) ? page.Title : Host(page.Url);

        public static string Host(string url)
        {
            if (string.IsNullOrEmpty(url))
                return "";
            var start = url.IndexOf("://", StringComparison.Ordinal);
            start = start < 0 ? 0 : start + 3;
            var end = url.IndexOfAny(new[] { '/', '?', '#' }, start);
            var host = end < 0 ? url.Substring(start) : url.Substring(start, end - start);
            return host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? host.Substring(4) : host;
        }

        // How long ago, in words, for the start page.
        public static string Ago(long now, long then)
        {
            var seconds = Math.Max(0, now - then);
            if (seconds < 60)
                return "just now";
            if (seconds < 3600)
                return $"{seconds / 60} min ago";
            if (seconds < 86400)
                return $"{seconds / 3600} h ago";
            var days = seconds / 86400;
            if (days == 1)
                return "yesterday";
            if (days < 30)
                return $"{days} days ago";
            return DateTimeOffset.FromUnixTimeSeconds(then).ToLocalTime().ToString("d MMM yyyy");
        }

        // What the start page draws: the bookmarks in the order they were added, and the most
        // recent pages, each with a label, a host and when. JSON for the page's own script.
        public string StartPageJson(long now)
        {
            var lists = new StartPageLists();
            foreach (var page in Bookmarks)
                lists.bookmarks.Add(new StartPageItem { url = page.Url, label = Label(page), host = Host(page.Url) });
            for (var i = 0; i < History.Count && i < k_StartPageHistory; i++)
            {
                var page = History[i];
                lists.history.Add(new StartPageItem { url = page.Url, label = Label(page), host = Host(page.Url), when = Ago(now, page.When) });
            }
            return JsonUtility.ToJson(lists);
        }

        [Serializable]
        class StartPageLists
        {
            public List<StartPageItem> bookmarks = new();
            public List<StartPageItem> history = new();
        }

        [Serializable]
        class StartPageItem
        {
            public string url;
            public string label;
            public string host;
            public string when;
        }

        public static BrowserStore Load(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    var store = JsonUtility.FromJson<BrowserStore>(File.ReadAllText(path));
                    if (store != null)
                    {
                        store.Bookmarks ??= new List<Page>();
                        store.History ??= new List<Page>();
                        store.Tabs ??= new List<Tab>();
                        return store;
                    }
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
            {
                Debug.LogWarning($"[WebXR] Couldn't read {Path.GetFileName(path)}: {e.Message}; starting afresh");
            }
            return new BrowserStore();
        }

        public bool Save(string path)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
                File.WriteAllText(path, JsonUtility.ToJson(this));
                Dirty = false;
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Debug.LogWarning($"[WebXR] Couldn't write {Path.GetFileName(path)}: {e.Message}");
                return false;
            }
        }

        public static long Now => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    }
}
