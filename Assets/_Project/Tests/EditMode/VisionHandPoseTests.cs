using Afterglow.Hands;
using NUnit.Framework;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    public class VisionHandPoseTests
    {
        // A plugin result for two hands: a left one at (100, 200) with every joint sure, and a
        // right one at (300, 400) with its thumb tip unsure.
        static float[] TwoHands()
        {
            const int handFloats = 2 + HandGeometry.JointCount * 3;
            var result = new float[1 + 2 * handFloats];
            result[0] = 2f;
            for (var h = 0; h < 2; h++)
            {
                var at = 1 + h * handFloats;
                result[at] = h == 0 ? 1f : 2f;
                result[at + 1] = 0.9f;
                for (var i = 0; i < HandGeometry.JointCount; i++)
                {
                    // Normalized, origin bottom left: a 640x480 upright image puts hand 0's wrist
                    // at (100, 200) and hand 1's at (300, 400) in pixels from the top left.
                    result[at + 2 + i * 3] = ((h == 0 ? 100f : 300f) + i) / 640f;
                    result[at + 3 + i * 3] = 1f - ((h == 0 ? 200f : 400f) + i) / 480f;
                    result[at + 4 + i * 3] = h == 1 && i == HandGeometry.ThumbTip ? 0.05f : 0.8f;
                }
            }
            return result;
        }

        [Test]
        public void Parse_ReadsBothHandsInTheAppsJointOrder()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];

            var count = VisionHandPose.Parse(TwoHands(), hands, 640, 480, 1);

            Assert.AreEqual(2, count);
            Assert.AreEqual(VisionHandPose.Chirality.Left, hands[0].chirality);
            Assert.AreEqual(VisionHandPose.Chirality.Right, hands[1].chirality);
            Assert.AreEqual(100f, hands[0].landmarks[0].x, 1e-3f);
            Assert.AreEqual(200f, hands[0].landmarks[0].y, 1e-3f);
            Assert.AreEqual(300f + HandGeometry.IndexTip, hands[1].landmarks[HandGeometry.IndexTip].x, 1e-3f);
            Assert.AreEqual(400f + HandGeometry.IndexTip, hands[1].landmarks[HandGeometry.IndexTip].y, 1e-3f);
            Assert.AreEqual(0.8f, hands[0].MeanConfidence, 1e-5f);
            Assert.AreEqual(0.05f, hands[1].confidences[HandGeometry.ThumbTip], 1e-6f);
            Assert.Less(hands[1].MeanConfidence, 0.8f);
        }

        [Test]
        public void Parse_ReportsAFailedRequestAsMinusOne()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];
            Assert.AreEqual(-1, VisionHandPose.Parse(new[] { -1f }, hands, 640, 480, 1));
            Assert.AreEqual(0, VisionHandPose.Parse(new[] { 0f }, hands, 640, 480, 1));
        }

        [Test]
        public void Parse_ReusesTheHandObjectsItIsGiven()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];
            VisionHandPose.Parse(TwoHands(), hands, 640, 480, 1);
            var first = hands[0];
            VisionHandPose.Parse(TwoHands(), hands, 640, 480, 1);
            Assert.AreSame(first, hands[0]);
        }

        // A point in the image as Vision would report it after each orientation, and back. The
        // given image is 640x480 with a mark at (600, 440) from the top left: near the bottom
        // right. Turned a quarter clockwise to be upright (6), a stored pixel (x, y) lands at
        // (H-1-y, x) in the upright image, so the mark is near its bottom left and Vision reports
        // it as about (0, 0); anticlockwise (8) sends (x, y) to (y, W-1-x); 5 is the transpose and
        // 7 the anti-transpose.
        [TestCase(1, 600f / 640f, 1f - 440f / 480f, TestName = "Upright: as given")]
        [TestCase(3, 1f - 600f / 640f, 440f / 480f, TestName = "Upside down")]
        [TestCase(6, 1f - 440f / 480f, 1f - 600f / 640f, TestName = "Quarter turn clockwise")]
        [TestCase(8, 440f / 480f, 600f / 640f, TestName = "Quarter turn anticlockwise")]
        [TestCase(2, 1f - 600f / 640f, 1f - 440f / 480f, TestName = "Mirrored upright")]
        [TestCase(4, 600f / 640f, 440f / 480f, TestName = "Mirrored upside down")]
        [TestCase(5, 440f / 480f, 1f - 600f / 640f, TestName = "Mirrored, quarter turn (5)")]
        [TestCase(7, 1f - 440f / 480f, 600f / 640f, TestName = "Mirrored, quarter turn (7)")]
        public void ToImage_TurnsVisionsPointBackIntoTheGivenImage(int orientation, float nx, float ny)
        {
            var p = VisionHandPose.ToImage(nx, ny, 640, 480, orientation);
            Assert.AreEqual(600f, p.x, 1e-3f, "x");
            Assert.AreEqual(440f, p.y, 1e-3f, "y");
        }

        // The eight ways the image can lie on the screen, as Vision names them.
        [TestCase(1f, 0f, 0f, -1f, 1, TestName = "Upright is 1")]
        [TestCase(-1f, 0f, 0f, 1f, 3, TestName = "Upside down is 3")]
        [TestCase(0f, -1f, -1f, 0f, 6, TestName = "Image x down the screen, y to the left, is 6")]
        [TestCase(0f, 1f, 1f, 0f, 8, TestName = "Image x up the screen, y to the right, is 8")]
        [TestCase(-1f, 0f, 0f, -1f, 2, TestName = "Mirrored upright is 2")]
        [TestCase(1f, 0f, 0f, 1f, 4, TestName = "Mirrored upside down is 4")]
        [TestCase(0f, -1f, 1f, 0f, 5, TestName = "Image x down, y to the right, is 5")]
        [TestCase(0f, 1f, -1f, 0f, 7, TestName = "Image x up, y to the left, is 7")]
        public void ImageOrientation_NamesEachWayTheImageCanLie(float xx, float xy, float yx, float yy, int expected)
        {
            Assert.AreEqual(expected, HandGeometry.ImageOrientation(new Vector2(xx, xy), new Vector2(yx, yy)));
        }

        [Test]
        public void ImageOrientation_AgreesWithTheAxesVariants()
        {
            // Variant 1 is the image upright; each variant is a known turn or flip, so every one
            // has to map to some orientation and the eight have to be distinct.
            var seen = new System.Collections.Generic.HashSet<int>();
            for (var variant = 1; variant <= 8; variant++)
            {
                HandGeometry.ImageAxesVariant(variant, out var x, out var y);
                var orientation = HandGeometry.ImageOrientation(x, y);
                Assert.That(orientation, Is.InRange(1, 8));
                seen.Add(orientation);
            }
            Assert.AreEqual(8, seen.Count);
            HandGeometry.ImageAxesVariant(1, out var upX, out var upY);
            Assert.AreEqual(1, HandGeometry.ImageOrientation(upX, upY));
        }

        [Test]
        public void FlatShape_PlacesTheHandAtTheDepthItsPalmSizeImplies()
        {
            // A palm 100 px across at a focal length of 1000 px, with a 5.5 cm palm: 55 cm away.
            var focal = new Vector2(1000f, 1000f);
            var principal = new Vector2(320f, 240f);
            var landmarks = new Vector2[HandGeometry.JointCount];
            for (var i = 0; i < landmarks.Length; i++)
                landmarks[i] = principal + new Vector2(10f * i, 7f * i);
            landmarks[0] = principal + new Vector2(0f, 60f);
            landmarks[5] = principal + new Vector2(-45f, -20f);
            landmarks[9] = principal + new Vector2(-15f, -40f);
            landmarks[13] = principal + new Vector2(15f, -40f);
            landmarks[17] = principal + new Vector2(45f, -20f);
            var shape = new Vector3[HandGeometry.JointCount];

            HandGeometry.FlatShape(landmarks, 0.055f, shape);
            var position = HandGeometry.FitPosition(landmarks, shape, HandGeometry.Palm, focal, principal, out var error);

            Assert.AreEqual(0.055f, HandGeometry.PalmSize(shape), 1e-4f);
            Assert.Less(error, 0.01f);
            var expectedDepth = focal.x * 0.055f / HandGeometry.PalmSpan(landmarks);
            Assert.AreEqual(expectedDepth, position.z, expectedDepth * 0.01f);
            foreach (var id in HandGeometry.Palm)
                Assert.AreEqual(0f, shape[id].z);
        }

        // The iPhone 18 Pro Max's display matrix: built for portrait (screen u drives the texture's
        // vertical axis) on a landscape screen. Passthrough draws the image as it comes, and so
        // must the hands: image x along the screen, y down it.
        [Test]
        public void ImageAxes_FollowPassthroughWhenTheMatrixIsPortraitOnALandscapeScreen()
        {
            var portraitBuilt = Matrix4x4.identity;
            portraitBuilt.m00 = 0f; portraitBuilt.m01 = -1f;
            portraitBuilt.m10 = -0.35f; portraitBuilt.m11 = 0f;
            portraitBuilt.m20 = 0.67f; portraitBuilt.m21 = 1f;

            HandGeometry.ImageAxesForScreen(portraitBuilt, 2868, 1320, -1, out var x, out var y);
            Assert.AreEqual(Vector2.right, x);
            Assert.AreEqual(Vector2.down, y);

            // camTurn 2: both axes flipped, as passthrough flips the picture.
            HandGeometry.ImageAxesForScreen(portraitBuilt, 2868, 1320, 2, out x, out y);
            Assert.AreEqual(Vector2.left, x);
            Assert.AreEqual(Vector2.up, y);

            // On a portrait screen the same matrix is right as it is, and the axes come from it.
            HandGeometry.ImageAxesForScreen(portraitBuilt, 1320, 2868, -1, out x, out y);
            HandGeometry.ImageAxesOnScreen(portraitBuilt, out var fromMatrix, out var fromMatrixY);
            Assert.AreEqual(fromMatrix, x);
            Assert.AreEqual(fromMatrixY, y);

            // camTurn 0 never turns, whatever the screen.
            HandGeometry.ImageAxesForScreen(portraitBuilt, 2868, 1320, 0, out x, out y);
            Assert.AreEqual(fromMatrix, x);
        }

        [Test]
        public void CameraRate_IsFullOnlyForAHandOrPassthroughThatShows()
        {
            Assert.IsTrue(PassthroughController.WantsFullRate(passthroughOn: true, coveredByPage: false, handsBusy: false));
            Assert.IsFalse(PassthroughController.WantsFullRate(passthroughOn: true, coveredByPage: true, handsBusy: false));
            Assert.IsTrue(PassthroughController.WantsFullRate(passthroughOn: true, coveredByPage: true, handsBusy: true));
            Assert.IsFalse(PassthroughController.WantsFullRate(passthroughOn: false, coveredByPage: false, handsBusy: false));
            Assert.IsTrue(PassthroughController.WantsFullRate(passthroughOn: false, coveredByPage: false, handsBusy: true));
        }
    }
}
