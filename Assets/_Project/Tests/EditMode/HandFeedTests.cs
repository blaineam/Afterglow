using CardboardXR.Hands;
using NUnit.Framework;
using UnityEngine.XR.Hands;

namespace CardboardXR.Stereo.Tests
{
    // Putting two hands on two sides.
    //
    // XR Hands has one slot per side, and the landmarker decides each hand's handedness on its
    // own from its own crop, so nothing stops it calling both of them the right hand. When it
    // does, one hand has nowhere to go and simply vanishes -- which looks exactly like the second
    // hand not being tracked at all.
    public class HandFeedTests
    {
        const float k_Margin = 0.2f;

        static HandFeed Hand(float rightChance)
        {
            var feed = new HandFeed(new TrackedHand(), 0.05f, 0.07f)
            {
                hasHand = true,
                rightChance = rightChance,
                isRight = rightChance >= 0.5f,
            };
            return feed;
        }

        [Test]
        public void TwoHandsOnDifferentSidesAreLeftAlone()
        {
            var left = Hand(0.1f);
            var right = Hand(0.9f);
            Assert.IsNull(HandFeed.MakeDistinct(left, right, k_Margin));
            Assert.AreEqual(Handedness.Left, left.Side);
            Assert.AreEqual(Handedness.Right, right.Side);
        }

        [Test]
        public void WhenBothReadRightTheLessSureOneMoves()
        {
            var sure = Hand(0.95f);
            var unsure = Hand(0.55f);

            var gave = HandFeed.MakeDistinct(unsure, sure, k_Margin);

            Assert.AreSame(unsure, gave, "the hand nearer to even is the one that gives way");
            Assert.AreEqual(Handedness.Right, sure.Side, "the confident hand keeps its side");
            Assert.AreEqual(Handedness.Left, unsure.Side);
        }

        [Test]
        public void WhenBothReadLeftTheLessSureOneMoves()
        {
            var sure = Hand(0.02f);
            var unsure = Hand(0.45f);

            var gave = HandFeed.MakeDistinct(sure, unsure, k_Margin);

            Assert.AreSame(unsure, gave);
            Assert.AreEqual(Handedness.Left, sure.Side);
            Assert.AreEqual(Handedness.Right, unsure.Side);
        }

        [Test]
        public void TheOrderOfTheArgumentsDoesNotDecideIt()
        {
            var a = Hand(0.95f);
            var b = Hand(0.55f);
            Assert.AreSame(b, HandFeed.MakeDistinct(a, b, k_Margin));

            var c = Hand(0.95f);
            var d = Hand(0.55f);
            Assert.AreSame(d, HandFeed.MakeDistinct(d, c, k_Margin));
        }

        [Test]
        public void AHandThatMovedStaysMoved()
        {
            // Its smoothed chance has to move with it. Left behind on the other side of even, the
            // next result would swap it straight back and the two hands would trade sides every
            // frame.
            var sure = Hand(0.95f);
            var unsure = Hand(0.55f);
            HandFeed.MakeDistinct(unsure, sure, k_Margin);

            Assert.Less(unsure.rightChance, 0.5f, "its chance moved across with its side");
            // And running it again is a no-op, rather than flipping it back.
            Assert.IsNull(HandFeed.MakeDistinct(unsure, sure, k_Margin));
            Assert.AreEqual(Handedness.Left, unsure.Side);
        }

        [Test]
        public void AHandThatIsNotThereIsNotMoved()
        {
            var right = Hand(0.9f);
            var absent = Hand(0.9f);
            absent.hasHand = false;

            Assert.IsNull(HandFeed.MakeDistinct(absent, right, k_Margin));
            Assert.AreEqual(Handedness.Right, right.Side, "the hand that is up keeps its side");
            Assert.AreEqual(Handedness.Invalid, absent.Side);
        }

        [Test]
        public void EachHandHasItsOwnPinch()
        {
            // Sharing one detector between hands would let either hand's fingers end the other's
            // pinch, which while dragging something with one hand would drop it.
            var a = Hand(0.1f);
            var b = Hand(0.9f);
            a.pinch.Update(0.01f);

            Assert.IsTrue(a.IsPinching);
            Assert.IsFalse(b.IsPinching);
        }
    }
}
