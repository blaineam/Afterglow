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
                    result[at + 2 + i * 3] = (h == 0 ? 100f : 300f) + i;
                    result[at + 3 + i * 3] = (h == 0 ? 200f : 400f) + i;
                    result[at + 4 + i * 3] = h == 1 && i == HandGeometry.ThumbTip ? 0.05f : 0.8f;
                }
            }
            return result;
        }

        [Test]
        public void Parse_ReadsBothHandsInTheAppsJointOrder()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];

            var count = VisionHandPose.Parse(TwoHands(), hands);

            Assert.AreEqual(2, count);
            Assert.AreEqual(VisionHandPose.Chirality.Left, hands[0].chirality);
            Assert.AreEqual(VisionHandPose.Chirality.Right, hands[1].chirality);
            Assert.AreEqual(new Vector2(100f, 200f), hands[0].landmarks[0]);
            Assert.AreEqual(new Vector2(300f + HandGeometry.IndexTip, 400f + HandGeometry.IndexTip), hands[1].landmarks[HandGeometry.IndexTip]);
            Assert.AreEqual(0.8f, hands[0].MeanConfidence, 1e-5f);
            Assert.AreEqual(0.05f, hands[1].confidences[HandGeometry.ThumbTip], 1e-6f);
            Assert.Less(hands[1].MeanConfidence, 0.8f);
        }

        [Test]
        public void Parse_ReportsAFailedRequestAsMinusOne()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];
            Assert.AreEqual(-1, VisionHandPose.Parse(new[] { -1f }, hands));
            Assert.AreEqual(0, VisionHandPose.Parse(new[] { 0f }, hands));
        }

        [Test]
        public void Parse_ReusesTheHandObjectsItIsGiven()
        {
            var hands = new VisionHandPose.Hand[VisionHandPose.MaxHands];
            VisionHandPose.Parse(TwoHands(), hands);
            var first = hands[0];
            VisionHandPose.Parse(TwoHands(), hands);
            Assert.AreSame(first, hands[0]);
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
