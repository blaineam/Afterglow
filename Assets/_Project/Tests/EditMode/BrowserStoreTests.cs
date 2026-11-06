using System.IO;
using Afterglow.Demos;
using NUnit.Framework;

namespace Afterglow.Stereo.Tests
{
    public class BrowserStoreTests
    {
        const long k_Now = 1_800_000_000;

        [Test]
        public void VisitsGoToTheTopCountedWithTheirLatestTitle()
        {
            var store = new BrowserStore();
            Assert.IsTrue(store.Visit("https://threejs.org/examples/", "three.js examples", k_Now));
            Assert.IsTrue(store.Visit("https://aframe.io/", "A-Frame", k_Now + 100));
            Assert.IsTrue(store.Visit("https://threejs.org/examples/", "three.js examples", k_Now + 200), "a later visit");
            Assert.AreEqual(2, store.History.Count);
            Assert.AreEqual("https://threejs.org/examples/", store.History[0].Url);
            Assert.AreEqual(2, store.History[0].Visits);
            Assert.AreEqual(k_Now + 200, store.History[0].When);
            Assert.IsTrue(store.Dirty);
        }

        [Test]
        public void TheSamePageMomentsLaterIsNotANewVisit()
        {
            var store = new BrowserStore();
            store.Visit("https://example.com/", "", k_Now);
            // The title arrives once the page has loaded: taken, not counted.
            Assert.IsTrue(store.Visit("https://example.com/", "Example", k_Now + 2));
            Assert.AreEqual(1, store.History[0].Visits);
            Assert.AreEqual("Example", store.History[0].Title);
            // Nothing new at all: no change to save.
            store.Dirty = false;
            Assert.IsFalse(store.Visit("https://example.com/", "Example", k_Now + 5));
            Assert.IsFalse(store.Dirty);
        }

        [Test]
        public void OnlyWebPagesAreRemembered()
        {
            var store = new BrowserStore();
            Assert.IsFalse(store.Visit("file:///var/app/webxr/index.html", "Afterglow", k_Now), "the start page");
            Assert.IsFalse(store.Visit("", "", k_Now));
            Assert.IsFalse(store.Visit("about:blank", "", k_Now));
            Assert.IsFalse(store.ToggleBookmark("file:///x.html", "x", k_Now));
            Assert.AreEqual(0, store.History.Count + store.Bookmarks.Count);
        }

        [Test]
        public void HistoryIsCapped()
        {
            var store = new BrowserStore();
            for (var i = 0; i < BrowserStore.k_HistoryLimit + 20; i++)
                store.Visit($"https://example.com/{i}", null, k_Now + i * 100);
            Assert.AreEqual(BrowserStore.k_HistoryLimit, store.History.Count);
            Assert.AreEqual($"https://example.com/{BrowserStore.k_HistoryLimit + 19}", store.History[0].Url, "newest first");
        }

        [Test]
        public void BookmarksToggle()
        {
            var store = new BrowserStore();
            Assert.IsFalse(store.IsBookmarked("https://aframe.io/"));
            Assert.IsTrue(store.ToggleBookmark("https://aframe.io/", "A-Frame", k_Now));
            Assert.IsTrue(store.IsBookmarked("https://aframe.io/"));
            Assert.IsFalse(store.ToggleBookmark("https://aframe.io/", "A-Frame", k_Now));
            Assert.IsFalse(store.IsBookmarked("https://aframe.io/"));
            Assert.AreEqual(0, store.Bookmarks.Count);
        }

        [Test]
        public void LabelsHostsAndAgo()
        {
            Assert.AreEqual("three.js", BrowserStore.Label(new BrowserStore.Page { Url = "https://threejs.org/x", Title = " three.js " }).Trim());
            Assert.AreEqual("threejs.org", BrowserStore.Label(new BrowserStore.Page { Url = "https://www.threejs.org/examples/?q=1" }));
            Assert.AreEqual("duckduckgo.com", BrowserStore.Host("https://duckduckgo.com/?q=vr"));
            Assert.AreEqual("", BrowserStore.Host(null));
            Assert.AreEqual("just now", BrowserStore.Ago(k_Now, k_Now - 10));
            Assert.AreEqual("5 min ago", BrowserStore.Ago(k_Now, k_Now - 300));
            Assert.AreEqual("3 h ago", BrowserStore.Ago(k_Now, k_Now - 3 * 3600));
            Assert.AreEqual("yesterday", BrowserStore.Ago(k_Now, k_Now - 86400));
            Assert.AreEqual("4 days ago", BrowserStore.Ago(k_Now, k_Now - 4 * 86400));
            StringAssert.Contains("20", BrowserStore.Ago(k_Now, k_Now - 60 * 86400), "a date");
        }

        [Test]
        public void TheStartPageGetsBookmarksAndRecentPages()
        {
            var store = new BrowserStore();
            store.ToggleBookmark("https://aframe.io/", "A-Frame", k_Now);
            for (var i = 0; i < BrowserStore.k_StartPageHistory + 5; i++)
                store.Visit($"https://example.com/{i}", $"Page {i}", k_Now + i);
            var json = store.StartPageJson(k_Now + 100);
            StringAssert.Contains("\"bookmarks\":[{\"url\":\"https://aframe.io/\",\"label\":\"A-Frame\",\"host\":\"aframe.io\"", json);
            StringAssert.Contains("\"label\":\"Page 16\"", json, "the newest page");
            StringAssert.DoesNotContain("\"label\":\"Page 0\"", json, "only the most recent dozen");
            StringAssert.Contains("\"when\":\"1 min ago\"", json);
            Assert.AreEqual("{\"bookmarks\":[],\"history\":[]}", new BrowserStore().StartPageJson(k_Now));
        }

        [Test]
        public void SavesAndLoadsTheLot()
        {
            var path = Path.Combine(Path.GetTempPath(), "afterglow-browser-test", BrowserStore.FileName);
            try
            {
                var store = new BrowserStore();
                store.Visit("https://example.com/", "Example", k_Now);
                store.ToggleBookmark("https://aframe.io/", "A-Frame", k_Now);
                store.RememberTabs(new[] { ("https://example.com/", "Example"), ("https://aframe.io/", "A-Frame") }, 1);
                Assert.IsTrue(store.Save(path));
                Assert.IsFalse(store.Dirty);

                var loaded = BrowserStore.Load(path);
                Assert.AreEqual(1, loaded.History.Count);
                Assert.AreEqual("Example", loaded.History[0].Title);
                Assert.IsTrue(loaded.IsBookmarked("https://aframe.io/"));
                Assert.AreEqual(2, loaded.Tabs.Count);
                Assert.AreEqual(1, loaded.SelectedTab);
                Assert.IsFalse(loaded.Dirty);

                File.WriteAllText(path, "not json {");
                UnityEngine.TestTools.LogAssert.Expect(UnityEngine.LogType.Warning, new System.Text.RegularExpressions.Regex("starting afresh"));
                var fresh = BrowserStore.Load(path);
                Assert.AreEqual(0, fresh.History.Count, "a broken file starts afresh");
                Assert.AreEqual(0, BrowserStore.Load(path + ".missing").History.Count);
            }
            finally
            {
                if (Directory.Exists(Path.GetDirectoryName(path)))
                    Directory.Delete(Path.GetDirectoryName(path), true);
            }
        }
    }
}
