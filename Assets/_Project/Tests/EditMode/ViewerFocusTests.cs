using NUnit.Framework;
using UnityEngine;

namespace CardboardXR.Stereo.Tests
{
    public class ViewerFocusTests
    {
        [SetUp]
        [TearDown]
        public void ClearOffset() => ViewerFocus.Reset();

        [Test]
        public void NoOffsetLeavesTheViewerAlone()
        {
            var viewer = ViewerParams.CardboardV2;
            Assert.AreSame(viewer, ViewerFocus.Apply(viewer));
        }

        [Test]
        public void OffsetMovesTheLensWithoutChangingTheProfile()
        {
            var viewer = ViewerParams.CardboardV2;
            ViewerFocus.Offset = 0.003f;

            var adjusted = ViewerFocus.Apply(viewer);
            Assert.AreEqual(0.0423f, adjusted.screenToLensDistance, 1e-6f);
            // The scanned profile is the source of truth and has to survive a rescan.
            Assert.AreEqual(0.0393f, viewer.screenToLensDistance, 1e-6f);
            // Nothing else about the viewer moves with the carriage.
            Assert.AreEqual(viewer.interLensDistance, adjusted.interLensDistance, 1e-6f);
            Assert.AreEqual(viewer.trayToLensDistance, adjusted.trayToLensDistance, 1e-6f);
            CollectionAssert.AreEqual(viewer.distortionCoefficients, adjusted.distortionCoefficients);
        }

        [Test]
        public void OffsetIsClampedToTheWheelsTravel()
        {
            ViewerFocus.Offset = 1f;
            Assert.AreEqual(ViewerFocus.MaxOffset, ViewerFocus.Offset, 1e-6f);
            ViewerFocus.Offset = -1f;
            Assert.AreEqual(ViewerFocus.MinOffset, ViewerFocus.Offset, 1e-6f);
        }

        // The distortion divides by the screen-to-lens distance, so it can never reach zero however
        // far the offset is pushed the wrong way.
        [Test]
        public void LensNeverReachesTheScreen()
        {
            var viewer = ViewerParams.CardboardV2.Clone();
            viewer.screenToLensDistance = 0.002f;
            ViewerFocus.Offset = ViewerFocus.MinOffset;

            Assert.Greater(ViewerFocus.Apply(viewer).screenToLensDistance, 0f);
        }

        [Test]
        public void ChangingTheOffsetTellsTheRigToRebuild()
        {
            var raised = 0;
            void Count() => raised++;
            ViewerFocus.Changed += Count;
            try
            {
                ViewerFocus.Offset = ViewerFocus.Step;
                Assert.AreEqual(1, raised);
                // Setting the same value again is not a change, so the rig doesn't rebuild.
                ViewerFocus.Offset = ViewerFocus.Step;
                Assert.AreEqual(1, raised);
            }
            finally
            {
                ViewerFocus.Changed -= Count;
            }
        }

        // The printed viewers use the 2015 Cardboard's lenses, so that profile has to match the one
        // decoded from a real viewer's QR code (ViewerParamsCodecTests.DecodesScannedCardboard2015Url).
        [Test]
        public void CardboardV2MatchesTheScannedViewer()
        {
            var viewer = ViewerParams.CardboardV2;
            Assert.AreEqual(0.0393f, viewer.screenToLensDistance, 1e-4f);
            Assert.AreEqual(0.0639f, viewer.interLensDistance, 1e-4f);
            Assert.AreEqual(0.035f, viewer.trayToLensDistance, 1e-4f);
            CollectionAssert.AreEqual(new[] { 60f, 60f, 60f, 60f }, viewer.leftEyeFieldOfViewAngles);
            Assert.That(viewer.distortionCoefficients, Is.EqualTo(new[] { 0.3358f, 0.5535f }).Within(1e-4f));
            Assert.AreEqual(ViewerParams.VerticalAlignment.Bottom, viewer.verticalAlignment);
        }

        [Test]
        public void CloneCopiesTheArraysRatherThanSharingThem()
        {
            var viewer = ViewerParams.CardboardV2;
            var copy = viewer.Clone();
            copy.leftEyeFieldOfViewAngles[0] = 1f;
            copy.distortionCoefficients[0] = 1f;

            Assert.AreEqual(60f, viewer.leftEyeFieldOfViewAngles[0], 1e-6f);
            Assert.AreEqual(0.3358f, viewer.distortionCoefficients[0], 1e-4f);
        }

        // What a bigger phone actually buys, which is not what it looks like. With the 2015
        // Cardboard's lenses the horizontal view is already lens-limited on a 6.1" phone: the
        // screen could subtend 61 degrees and the profile allows 60, so a 6.9" phone's 72 degrees
        // of screen is simply outside what the lens renders and is thrown away. Vertically there is
        // real room: the 6.1" phone's screen runs out at about 52 degrees, short of the lens, and
        // the taller screen reaches the full 60. So the gain from the 18 Pro Max is a taller view,
        // not a wider one, and raising the profile's limits would only push the image past the
        // lens's usable field.
        [Test]
        public void ABiggerPhoneBuysVerticalFieldOfViewNotHorizontal()
        {
            var viewer = ViewerParams.CardboardV2;
            // iPhone 15 Pro and iPhone 18 Pro Max active areas, in meters.
            var small = new LensDistortion(viewer, 0.1411f, 0.0651f).GetFieldOfView(Eye.Left) * Mathf.Rad2Deg;
            var large = new LensDistortion(viewer, 0.1584f, 0.0729f).GetFieldOfView(Eye.Left) * Mathf.Rad2Deg;

            Assert.Greater(large.w, small.w, "the taller screen should reach higher");
            Assert.AreEqual(60f, large.w, 0.5f, "and reach the lens's own limit");
            Assert.AreEqual(51.9f, small.w, 0.5f, "while the smaller screen runs out before it");

            // Both phones are already lens-limited across, so the wider screen changes nothing.
            Assert.AreEqual(60f, small.x, 0.5f);
            Assert.AreEqual(60f, large.x, 0.5f);
            // The inner edge and the bottom are set by the lens spacing and the tray, not the screen.
            Assert.AreEqual(small.y, large.y, 1e-3f);
            Assert.AreEqual(small.z, large.z, 1e-3f);
        }

    }
}
