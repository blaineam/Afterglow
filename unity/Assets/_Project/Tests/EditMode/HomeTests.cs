using System.Collections.Generic;
using Afterglow.Demos;
using NUnit.Framework;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    public class HomeTests
    {
        static DemoCatalog.Entry Entry(string id, DemoCatalog.Section section) =>
            new() { Id = id, Title = id, Section = section };

        [Test]
        public void SectionsAreMediaWebFilesPlaySettings()
        {
            var tiles = HomeScreen.Sections(webSupported: true);
            Assert.AreEqual(HomeScreen.k_SectionCount, tiles.Length);
            CollectionAssert.AreEqual(
                new[] { HomeScreen.Section.Media, HomeScreen.Section.Web, HomeScreen.Section.Files, HomeScreen.Section.Play, HomeScreen.Section.Settings },
                System.Array.ConvertAll(tiles, tile => tile.Section));
            foreach (var tile in tiles)
            {
                Assert.IsTrue(tile.Enabled, tile.Title);
                Assert.IsNotEmpty(tile.Tagline, tile.Title);
                Assert.IsNotEmpty(UI.M3Icons.Glyph(tile.Icon), $"{tile.Title}'s icon {tile.Icon} is in the icon table");
            }
        }

        [Test]
        public void WebIsDisabledWhereTheBrowserIsnt()
        {
            var web = HomeScreen.Sections(webSupported: false)[1];
            Assert.AreEqual(HomeScreen.Section.Web, web.Section);
            Assert.IsFalse(web.Enabled);
            StringAssert.Contains("iOS", web.Tagline);
        }

        [Test]
        public void SizeGrowsByTheRow()
        {
            var one = HomeScreen.Size(3);
            var two = HomeScreen.Size(4);
            Assert.AreEqual(one.x, two.x);
            Assert.AreEqual(one.y + HomeScreen.k_CellHeight + 8f, two.y, 1e-3f);
            Assert.AreEqual(HomeScreen.Size(5), HomeScreen.Size(6));
            Assert.AreEqual(HomeScreen.Size(1), HomeScreen.Size(0), "an empty page is still one row tall");
        }

        [Test]
        public void CellsFillRowsLeftToRightUnderTheHeader()
        {
            var size = HomeScreen.Size(6);
            var first = HomeScreen.CellPosition(0, size);
            var second = HomeScreen.CellPosition(1, size);
            var fourth = HomeScreen.CellPosition(3, size);
            Assert.AreEqual(first.y, second.y);
            Assert.AreEqual(HomeScreen.k_CellWidth + 8f, second.x - first.x, 1e-3f);
            Assert.AreEqual(first.x, fourth.x);
            Assert.AreEqual(HomeScreen.k_CellHeight + 8f, first.y - fourth.y, 1e-3f);
            // Under the header: the top row's top edge is header, gap and padding below the screen's top.
            Assert.AreEqual(size.y / 2f - 16f - HomeScreen.k_Header - 8f, first.y + HomeScreen.k_CellHeight / 2f, 1e-3f);
            // And within the width.
            Assert.AreEqual(-size.x / 2f + 16f, first.x - HomeScreen.k_CellWidth / 2f, 1e-3f);
            Assert.AreEqual(size.x / 2f - 16f, HomeScreen.CellPosition(2, size).x + HomeScreen.k_CellWidth / 2f, 1e-3f);
        }

        [Test]
        public void CatalogSplitsBySection()
        {
            var entries = new List<DemoCatalog.Entry>
            {
                Entry("sandbox", DemoCatalog.Section.Play), Entry("video", DemoCatalog.Section.Media), Entry("room", DemoCatalog.Section.Play),
            };
            var play = DemoCatalog.InSection(entries, DemoCatalog.Section.Play);
            CollectionAssert.AreEqual(new[] { "sandbox", "room" }, play.ConvertAll(entry => entry.Id));
            Assert.AreEqual("video", DemoCatalog.InSection(entries, DemoCatalog.Section.Media)[0].Id);

            var catalog = ScriptableObject.CreateInstance<DemoCatalog>();
            try
            {
                Assert.IsEmpty(catalog.InSection(DemoCatalog.Section.Media));
                Assert.AreEqual("Assets/_Project/Demos/Home/Home.unity", catalog.HomeScenePath);
            }
            finally
            {
                Object.DestroyImmediate(catalog);
            }
        }

        [Test]
        public void TheRunningDotFollowsWhatIsOpen()
        {
            var player = Entry("video", DemoCatalog.Section.Media);
            var game = Entry("rush", DemoCatalog.Section.Play);
            Assert.IsNull(HomeScreen.Running(null, null, false));
            Assert.AreEqual(HomeScreen.Section.Media, HomeScreen.Running(player, null, false));
            Assert.AreEqual(HomeScreen.Section.Files, HomeScreen.Running(player, HomeScreen.k_FilesArgument, false));
            Assert.AreEqual(HomeScreen.Section.Play, HomeScreen.Running(game, null, false));
            // The browser is a window over whatever runs, and the one the user sees.
            Assert.AreEqual(HomeScreen.Section.Web, HomeScreen.Running(game, null, true));
        }

        [Test]
        public void TheRoomIsScannedOnlyWhenAnAppNeedsItAndNothingHas()
        {
            var sandbox = new DemoRequirements { SixDof = Need.On, Passthrough = Need.On, Hands = Need.On, ScanSurfaces = true };
            var sixDof = new CoreState(true, true, true);
            Assert.IsTrue(DemoManager.WantsScan(sandbox, sixDof, hasScannedRoom: false, scanSetting: true));
            Assert.IsFalse(DemoManager.WantsScan(sandbox, sixDof, hasScannedRoom: true, scanSetting: true), "scanned already");
            Assert.IsFalse(DemoManager.WantsScan(sandbox, sixDof, hasScannedRoom: false, scanSetting: false), "the setting is off");
            Assert.IsFalse(DemoManager.WantsScan(sandbox, new CoreState(false, false, false), false, true), "no 6DoF to scan with");
            Assert.IsFalse(DemoManager.WantsScan(new DemoRequirements { SixDof = Need.On }, sixDof, false, true), "the app didn't ask");
        }
    }
}
