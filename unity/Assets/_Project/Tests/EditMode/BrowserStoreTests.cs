using System.IO;
using Afterglow.Demos;
using NUnit.Framework;
using UnityEngine;

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

namespace Afterglow.Stereo.Tests
{
    public class WebHandsTests
    {
        [Test]
        public void HandsToPage_PacksTrackedHandsWithZTheOtherWay()
        {
            var left = new Afterglow.Hands.TrackedHand { isTracking = true, handednessScore = 0.1f };
            var right = new Afterglow.Hands.TrackedHand { isTracking = true, handednessScore = 0.9f };
            var idle = new Afterglow.Hands.TrackedHand { isTracking = false };
            for (var i = 0; i < Afterglow.Hands.HandGeometry.JointCount; i++)
            {
                left.joints[i] = new UnityEngine.Vector3(i, 1f, 2f);
                right.joints[i] = new UnityEngine.Vector3(-i, 3f, -4f);
            }
            var values = new float[1 + 2 * Afterglow.Stereo.WebBrowser.FloatsPerHand];

            var count = Afterglow.Demos.WebBrowserSession.HandsToPage(new[] { idle, right, left }, h => h == right, h => h.handednessScore >= 0.5f, values);

            Assert.AreEqual(2, count);
            Assert.AreEqual(2f, values[0]);
            // The right hand first, pinching, its joints with z flipped.
            Assert.AreEqual(1f, values[1]);
            Assert.AreEqual(1f, values[2]);
            Assert.AreEqual(-5f, values[3 + 5 * 3]);
            Assert.AreEqual(3f, values[4 + 5 * 3]);
            Assert.AreEqual(4f, values[5 + 5 * 3]);
            // Then the left, not pinching.
            var at = 1 + Afterglow.Stereo.WebBrowser.FloatsPerHand;
            Assert.AreEqual(0f, values[at]);
            Assert.AreEqual(0f, values[at + 1]);
            Assert.AreEqual(-2f, values[at + 4]);
        }
    }
}

namespace Afterglow.Stereo.Tests
{
    public class PanoramaEnvironmentTests
    {
        [Test]
        public void BuildSphere_FacesInwardWithEquirectangularCoordinates()
        {
            var mesh = Afterglow.Demos.PanoramaEnvironment.BuildSphere(10f, 8, 4);
            var vertices = mesh.vertices;
            var uvs = mesh.uv;
            var triangles = mesh.triangles;

            Assert.AreEqual(9 * 5, vertices.Length);
            Assert.AreEqual(8 * 4 * 6, triangles.Length);
            foreach (var v in vertices)
                Assert.AreEqual(10f, v.magnitude, 1e-3f);
            // The picture's middle (u 0.5) is straight ahead, its bottom (v 0) at the bottom.
            var ahead = System.Array.FindIndex(uvs, uv => Mathf.Abs(uv.x - 0.5f) < 1e-4f && Mathf.Abs(uv.y - 0.5f) < 1e-4f);
            Assert.GreaterOrEqual(ahead, 0);
            Assert.Greater(vertices[ahead].z, 9.9f);
            var bottom = System.Array.FindIndex(uvs, uv => uv.y < 1e-4f);
            Assert.Less(vertices[bottom].y, -9.9f);
            // Every triangle's normal points at the centre: seen from inside.
            for (var t = 0; t < triangles.Length; t += 3)
            {
                var a = vertices[triangles[t]]; var b = vertices[triangles[t + 1]]; var c = vertices[triangles[t + 2]];
                var normal = Vector3.Cross(b - a, c - a);
                if (normal.sqrMagnitude < 1e-6f) continue;
                Assert.Less(Vector3.Dot(normal, (a + b + c) / 3f), 0f, "a triangle faces outward");
            }
        }

        [Test]
        public void Describe_NamesTheBuiltInOrThePhoto()
        {
            var files = new[] { "/x/Beach.jpg", "/x/Moon.png" };
            Assert.AreEqual("Synthwave", Afterglow.Demos.PanoramaEnvironment.Describe(0, files));
            Assert.AreEqual("Beach", Afterglow.Demos.PanoramaEnvironment.Describe(1, files));
            Assert.AreEqual("Moon", Afterglow.Demos.PanoramaEnvironment.Describe(2, files));
            Assert.AreEqual("Synthwave", Afterglow.Demos.PanoramaEnvironment.Describe(3, files));
        }

        [Test]
        public void Environments_ShowOneOrTheOther_AndNeitherInPassthrough()
        {
            Assert.IsTrue(VirtualEnvironment.Shows(isReplacement: false, hidden: false, replaced: false));
            Assert.IsFalse(VirtualEnvironment.Shows(isReplacement: true, hidden: false, replaced: false));
            Assert.IsFalse(VirtualEnvironment.Shows(isReplacement: false, hidden: false, replaced: true));
            Assert.IsTrue(VirtualEnvironment.Shows(isReplacement: true, hidden: false, replaced: true));
            Assert.IsFalse(VirtualEnvironment.Shows(isReplacement: true, hidden: true, replaced: true));
            Assert.IsFalse(VirtualEnvironment.Shows(isReplacement: false, hidden: true, replaced: false));
        }
    }
}

namespace Afterglow.Stereo.Tests
{
    public class AppLockTests
    {
        [Test]
        public void Record_MatchesOnlyItsOwnPin()
        {
            var record = Afterglow.Demos.AppLock.NewRecord("123456");
            Assert.IsTrue(Afterglow.Demos.AppLock.Matches(record, "123456"));
            Assert.IsFalse(Afterglow.Demos.AppLock.Matches(record, "123457"));
            Assert.IsFalse(Afterglow.Demos.AppLock.Matches(record, ""));
            Assert.IsFalse(Afterglow.Demos.AppLock.Matches("", "123456"));
            Assert.IsFalse(Afterglow.Demos.AppLock.Matches("nosalt", "123456"));
            // The record never holds the PIN, and two records for one PIN differ by their salt.
            Assert.IsFalse(record.Contains("123456"));
            Assert.AreNotEqual(record, Afterglow.Demos.AppLock.NewRecord("123456"));
        }

        [Test]
        public void IsPin_IsSixDigits()
        {
            Assert.IsTrue(Afterglow.Demos.AppLock.IsPin("000000"));
            Assert.IsFalse(Afterglow.Demos.AppLock.IsPin("12345"));
            Assert.IsFalse(Afterglow.Demos.AppLock.IsPin("12345a"));
            Assert.IsFalse(Afterglow.Demos.AppLock.IsPin(null));
        }
    }
}
