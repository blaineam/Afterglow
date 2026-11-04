using UnityEngine;

namespace CardboardXR.Hands
{
    // Everything HandTracker knows about one hand.
    //
    // Split out so the tracker can follow two. What stays on the tracker is what the two hands
    // share: the models, the camera image and its pose history, and the calibration -- the user's
    // palm size and the depth sensor's bias belong to the person, not to a hand, so a hand that
    // has just been found starts with what the other one taught.
    //
    // Plain mutable fields on purpose. This is the tracker's own working state, written in the
    // middle of the inference loop, and properties with backing stores would only hide that.
    public sealed class TrackedHand
    {
        // Where in the camera image the landmarker looks next, or null when there is no hand here
        // and the palm detector has to find one.
        public HandRegion? region;
        // Whether the region came from the palm detector and no result has been taken from it yet:
        // a new hand, which has to be within reach, rather than one already being followed.
        public bool acquiring;
        // When the landmarker may next run for this hand. Per hand, since they are found at
        // different times and each one's cadence runs from its own last result.
        public float nextTrack;

        // The latest result's 21 landmarks in the camera image, in pixels (x right, y down).
        public readonly Vector2[] imageLandmarks = new Vector2[HandGeometry.JointCount];
        // And its 3D shape, in meters, scaled to the user's palm.
        public readonly Vector3[] metricLandmarks = new Vector3[HandGeometry.JointCount];
        // The joints in the camera's own space, before they are put into the world.
        public readonly Vector3[] cameraJoints = new Vector3[HandGeometry.JointCount];

        // The last shape that fit its landmarks, and its smoothed depth, for images whose shape
        // collapsed.
        public readonly Vector3[] goodShape = new Vector3[HandGeometry.JointCount];
        public bool hasGoodShape;
        public float goodDepth;

        // One Euro filter settings: the cutoff in Hz when still, and how much it rises per m/s.
        const float k_JointMinCutoff = 1.5f;
        const float k_JointBeta = 8f;
        const float k_DepthMinCutoff = 1f;
        const float k_DepthBeta = 4f;

        // Smooths each joint, and the hand's depth before the joints are placed with it. A filter
        // holds the state of the hand it smooths, so each hand needs its own set: sharing them
        // would make one hand's motion drag on the other's.
        public readonly OneEuroFilter[] jointFilters = CreateJointFilters();
        public readonly OneEuroFilter depthFilter = new(k_DepthMinCutoff, k_DepthBeta);

        static OneEuroFilter[] CreateJointFilters()
        {
            var filters = new OneEuroFilter[HandGeometry.JointCount];
            for (var i = 0; i < filters.Length; i++)
                filters[i] = new OneEuroFilter(k_JointMinCutoff, k_JointBeta);
            return filters;
        }

        // The latest result's smoothed joints and their image's time, and the palm's smoothed
        // speed, which every joint is moved on by between results.
        public readonly Vector3[] resultJoints = new Vector3[HandGeometry.JointCount];
        public Vector3 speed;
        public long resultImageNs;

        // What the rest of the app reads: the joints as shown, moved on from the last result.
        public readonly Vector3[] joints = new Vector3[HandGeometry.JointCount];
        public bool isTracking;
        public float distance;
        public float pinchDistance;
        public float pinchRatio;
        public float presence;
        public bool shapeFits;
        // The landmarker's handedness, as the chance that this is a right hand.
        public float handednessScore;

        // The previous result, for logging jumps in distance.
        public float lastDistance;
        public float lastPalmSpan;
        public float lastResultTime = float.NegativeInfinity;

        // Lets go of the hand and everything learned from its last results.
        public void Forget()
        {
            isTracking = false;
            region = null;
            foreach (var filter in jointFilters)
                filter.Reset();
            depthFilter.Reset();
            speed = Vector3.zero;
            hasGoodShape = false;
        }
    }
}
