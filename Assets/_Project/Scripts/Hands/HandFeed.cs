using UnityEngine;
using UnityEngine.XR.Hands;

namespace CardboardXR.Hands
{
    // One hand's worth of what HandSubsystemFeed reports to XR Hands: which side it is, its joints
    // in the tracking space, and its pinch.
    //
    // Split out so the feed can carry two, one per hand the tracker follows. Each needs its own
    // pinch detector and turn gate, because both are state machines about a particular hand --
    // sharing them would let one hand's pinch end the other's.
    public sealed class HandFeed
    {
        // The tracker hand this follows, for its whole life: the tracker's slots are stable, so
        // the pairing never has to be worked out again.
        public readonly TrackedHand hand;
        public readonly PinchDetector pinch;
        public readonly HandTurnGate turn = new();
        public readonly Vector3[] landmarks = new Vector3[HandGeometry.JointCount];
        public readonly Pose[] joints = new Pose[HandSkeleton.JointCount];

        public bool hasHand;
        public bool isRight;
        // The smoothed chance that this is a right hand.
        public float rightChance;
        public int lastResult = -1;
        public int pinchResult = -1;
        public int openResults;
        public float lostSince = -1f;
        public bool loggedEdge;
        public bool loggedTurn;

        public HandFeed(TrackedHand hand, float pinchDistance, float releaseDistance)
        {
            this.hand = hand;
            pinch = new PinchDetector(pinchDistance, releaseDistance);
        }

        public Handedness Side => !hasHand ? Handedness.Invalid : isRight ? Handedness.Right : Handedness.Left;

        public string SideName => isRight ? "right" : "left";

        public bool IsPinching => pinch.IsPinched;

        // How sure this hand's side is, as its distance from even. Used to settle which hand
        // gives way when both read as the same side.
        public float SideConfidence => Mathf.Abs(rightChance - 0.5f);

        public void Forget()
        {
            hasHand = false;
            turn.Reset();
            openResults = 0;
        }

        // Settles two hands onto different sides. XR Hands has one slot per side, and the
        // landmarker decides each hand on its own, so nothing stops it calling both of them the
        // right hand -- and then one hand would have nowhere to go.
        //
        // The one less sure of itself gives way, so the hand the model is confident about keeps
        // the side it was given. Their positions in the image would be another way to settle it,
        // since hands rarely cross over, but that is a guess about the user where this is the
        // model's own confidence.
        //
        // Returns the hand that gave way, or null if they were already on different sides. It has
        // to be returned rather than worked out again afterwards: moving a hand's side also moves
        // its smoothed chance, so after the fact the two confidences no longer say who moved.
        public static HandFeed MakeDistinct(HandFeed a, HandFeed b, float margin)
        {
            if (a == null || b == null || !a.hasHand || !b.hasHand || a.isRight != b.isRight)
                return null;
            var giving = a.SideConfidence < b.SideConfidence ? a : b;
            giving.isRight = !giving.isRight;
            // Its smoothed chance moves across with it, or the next result swaps it straight back
            // and the two hands trade sides every frame.
            giving.rightChance = giving.isRight ? 0.5f + margin : 0.5f - margin;
            return giving;
        }
    }
}
