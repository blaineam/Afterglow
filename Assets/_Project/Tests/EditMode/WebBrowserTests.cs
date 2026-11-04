using CardboardXR.Demos;
using NUnit.Framework;
using UnityEngine;

namespace CardboardXR.Stereo.Tests
{
    // The browser window's one piece of geometry: where on the page a point on the quad is.
    //
    // Worth its own tests because getting it backwards is invisible. It mirrors every click
    // vertically, and on a page full of links a mirrored click still lands on something often
    // enough that the browser looks erratic rather than aimed at the wrong place -- which is
    // exactly how it was reported, and how it was shipped.
    public class WebBrowserTests
    {
        // What the material actually shows at a point on the quad, worked out from the two things
        // that decide it, so this is a check and not a restatement of PageV.
        //
        //   quad UV:  v = localY + 0.5          (+0.5 at the top of the quad, -0.5 at the bottom)
        //   material: flipped, v -> 1 - v       (mainTextureScale.y -1, mainTextureOffset.y 1)
        //   capture:  texture v 0 is the page's TOP row, because the snapshot writes the page's
        //             first row first and Unity reads a texture's first row as v 0.
        //
        // So the fraction of the page on show at a point is just the texture v sampled there.
        static float DisplayedPageFraction(float localY, bool flipV)
        {
            var quadV = localY + 0.5f;
            return flipV ? 1f - quadV : quadV;
        }

        [TestCase(true)]
        [TestCase(false)]
        public void TheClickTargetIsWhateverIsOnShowThere(bool flipV)
        {
            // Across the whole height of the window, including both edges.
            for (var i = 0; i <= 20; i++)
            {
                var localY = -0.5f + i / 20f;
                Assert.AreEqual(DisplayedPageFraction(localY, flipV), WebBrowserSession.PageV(localY, flipV),
                                1e-6f, $"at local y {localY:F3} with flipV {flipV}");
            }
        }

        [Test]
        public void AsShipped_LookingHighHitsTheTopOfThePage()
        {
            // flipV true is the configuration that puts the page the right way up, so it is the
            // one that has to be right. The top of the window is page fraction 0.
            Assert.AreEqual(0f, WebBrowserSession.PageV(0.5f, true), 1e-6f, "the top of the window");
            Assert.AreEqual(0.5f, WebBrowserSession.PageV(0f, true), 1e-6f, "the middle");
            Assert.AreEqual(1f, WebBrowserSession.PageV(-0.5f, true), 1e-6f, "the bottom of the window");
        }

        [Test]
        public void TheMappingRunsDownThePage_NotUpIt()
        {
            // The direction on its own, stated plainly: lower on the window is further down the
            // page. Gaze-scrolling reads the same number, so getting this backwards scrolled the
            // page the wrong way as well as clicking the wrong place.
            Assert.Less(WebBrowserSession.PageV(0.4f, true), WebBrowserSession.PageV(-0.4f, true));
        }

        [Test]
        public void EveryPointOnTheQuadLandsOnThePage()
        {
            for (var i = 0; i <= 20; i++)
            {
                var v = WebBrowserSession.PageV(-0.5f + i / 20f, true);
                Assert.That(v, Is.InRange(0f, 1f));
            }
        }

        // What typing into the address bar does with what was typed. The interesting cases are
        // the ones where a browser is visibly wrong: a search treated as a host, or a host sent
        // to a search engine.
        [TestCase("https://immersiveweb.dev", "https://immersiveweb.dev")]
        [TestCase("http://example.com/a/b", "http://example.com/a/b")]
        [TestCase("about:blank", "about:blank")]
        [TestCase("immersiveweb.dev", "https://immersiveweb.dev")]
        [TestCase("example.com/path?q=1", "https://example.com/path?q=1")]
        [TestCase("  example.com  ", "https://example.com")]
        // A port is not a scheme, which is what matching on a bare colon would make of it.
        [TestCase("localhost:8080", "https://localhost:8080")]
        [TestCase("localhost", "https://localhost")]
        public void AnAddressIsTakenAsOne(string typed, string expected)
        {
            Assert.AreEqual(expected, WebBrowser.NormalizeAddress(typed));
        }

        [TestCase("webxr samples")]
        [TestCase("what is a spatial photo")]
        // A dot does not make it a host when there is a space in it.
        [TestCase("compare example.com and the other one")]
        [TestCase("hello")]
        // The end of a sentence, not a domain.
        [TestCase("is that so.")]
        public void AnythingElseIsASearch(string typed)
        {
            var result = WebBrowser.NormalizeAddress(typed);
            Assert.That(result, Does.StartWith("https://duckduckgo.com/?q="), result);
            // And the text survives being put in a query, spaces and all.
            Assert.AreEqual(typed.Trim(),
                System.Uri.UnescapeDataString(result.Substring("https://duckduckgo.com/?q=".Length)));
        }

        [TestCase(null)]
        [TestCase("")]
        [TestCase("   ")]
        public void NothingTypedGoesNowhere(string typed)
        {
            Assert.IsNull(WebBrowser.NormalizeAddress(typed));
        }

        [Test]
        public void TheAddressBarDropsWhatIsNotWorthReading()
        {
            Assert.AreEqual("immersiveweb.dev", WebBrowserSession.ShortenUrl("https://immersiveweb.dev/"));
            Assert.AreEqual("example.com/a", WebBrowserSession.ShortenUrl("https://www.example.com/a"));
            Assert.AreEqual("", WebBrowserSession.ShortenUrl(null));
        }

        [Test]
        public void ALongAddressKeepsBothItsEnds()
        {
            // The host is at the front and the page's name at the end, so the middle is what goes.
            var url = "https://example.com/" + new string('x', 200) + "/the-page.html";
            var shown = WebBrowserSession.ShortenUrl(url, 40);
            Assert.That(shown.Length, Is.LessThanOrEqualTo(40), shown);
            Assert.That(shown, Does.StartWith("example.com/"), shown);
            Assert.That(shown, Does.EndWith("page.html"), shown);
            Assert.That(shown, Does.Contain("…"), shown);
        }
    }
}
