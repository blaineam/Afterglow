using System.Collections.Generic;
using UnityEngine;
using UnityEngine.XR.Hands;
using UnityEngine.XR.Hands.Configuration;
using UnityEngine.XR.Hands.ProviderImplementation;

namespace Afterglow.Hands
{
    // Runs the XR Hands subsystem for the camera-tracked hands (CardboardHandProvider) and supplies
    // it: HandTracker's joints in the XR Origin's tracking space, where XR Hands' poses are, as the
    // left and right hand by the landmarker's handedness; the pointing ray, from the eyes through the
    // point between the thumb and index fingertips, as the aim pose; and the pinch. XR Hands updates
    // the hands early in each frame and again just before rendering, and XRHandDevice passes them on
    // to input actions. Put it on the XR Origin. It runs after HandTracker and before HandInteractorRig
    // and XRI's interaction manager, which use its pinch. Logs [Hands].
    //
    // One HandFeed per hand the tracker follows, paired to its slot for good. Each carries its own
    // pinch detector and turn gate, since both are state machines about a particular hand.
    [DefaultExecutionOrder(-115)]
    public class HandSubsystemFeed : MonoBehaviour
    {
        internal enum PoseKind { Aim, Grip, Pinch, Poke }

        // The handedness is smoothed over results, and a hand only changes sides when the smoothed
        // chance of a right hand is this far past even, so a wavering reading doesn't swap it.
        const float k_HandednessRate = 0.3f;
        const float k_SideChangeMargin = 0.2f;
        const float k_StatusSeconds = 5f;

        [SerializeField] HandTracker m_Tracker;
        [Tooltip("The XR Origin's camera offset, which XR Hands' poses are relative to; this object if unset.")]
        [SerializeField] Transform m_TrackingSpace;
        [Tooltip("The eyes: the pointing ray runs from them through the point between the thumb and index fingertips.")]
        [SerializeField] Transform m_Eyes;
        // From the pinch study: fingertips about 2-3 cm apart pinched and 9.5-10.4 cm open.
        [Tooltip("Fingertips closer than this, in meters, start a pinch.")]
        [SerializeField] float m_PinchDistance = 0.05f;
        [Tooltip("Fingertips farther apart than this, in meters, end a pinch.")]
        [SerializeField] float m_ReleaseDistance = 0.07f;
        [Tooltip("Fingertips at least this far apart, in meters, give a pinch value of 0.")]
        [SerializeField] float m_OpenDistance = 0.09f;
        [Tooltip("Fingertips this far apart in the image, over the palm's width there, end a pinch " +
                 "whatever the hand's 3D shape says. The pinch study measured about 0.23 pinched and " +
                 "1.8 to 2.1 open.")]
        [SerializeField] float m_OpenRatio = 1f;
        [Tooltip("A flat shape (one with no depth of its own) pinches when the fingertips are closer than this share of the palm's width in the image.")]
        [SerializeField] float m_CloseRatio = 0.4f;

        // Frames where the image gap read open while the fitting 3D shape held the pinch, for the
        // status line.
        int m_IgnoredOpens;

        static readonly List<XRHandSubsystemDescriptor> s_Descriptors = new();

        XRHandSubsystem m_Subsystem;
        XRHandProviderUtility.SubsystemUpdater m_Updater;
        readonly List<HandFeed> m_Feeds = new();
        // A pinch only ends on k_OpenResults tracker results in a row that read the fingers open, with
        // the hand at least k_EdgeMargin of the image from its edge: telling letting go from the hand
        // leaving the camera's view, where most losses happen (0-10% from the edge in the logs; false
        // opens read at most 2%, so 3% holds back few real releases).
        const int k_OpenResults = 2;
        // Longer than HandInteractorRig's m_LostSeconds (0.25 s).
        const float k_PinchKeptSeconds = 0.3f;
        const float k_EdgeMargin = 0.03f;
        float m_StatusStart;
        // XR Hands' updates since the last status line, early in the frame and just before rendering.
        int m_EarlyUpdates;
        int m_BeforeRenderUpdates;

        // The feed the single-hand API reports: the first one with a hand.
        HandFeed Primary
        {
            get
            {
                foreach (var feed in m_Feeds)
                {
                    if (feed.hasHand)
                        return feed;
                }
                return m_Feeds.Count > 0 ? m_Feeds[0] : null;
            }
        }

        // Which hand is being reported, or Invalid while none is.
        public Handedness TrackedHandedness => Primary?.Side ?? Handedness.Invalid;

        // Whether either hand is pinching, which is what the one-handed callers meant by it.
        public bool IsPinching
        {
            get
            {
                foreach (var feed in m_Feeds)
                {
                    if (feed.hasHand && feed.IsPinching)
                        return true;
                }
                return false;
            }
        }

        // Whether that particular hand is pinching. What a caller drawing one hand wants: with
        // two up, "is anything pinching" would swell the fingertips of a hand resting at your side
        // because the other one pinched.
        // Which side a tracked hand is taken for, with this feed's hysteresis (a wavering reading
        // doesn't swap it). False when the hand isn't fed.
        public bool TryGetSide(TrackedHand hand, out bool isRight)
        {
            foreach (var feed in m_Feeds)
            {
                if (feed.hand == hand && feed.hasHand)
                {
                    isRight = feed.isRight;
                    return true;
                }
            }
            isRight = false;
            return false;
        }

        public bool IsPinchingWith(TrackedHand hand)
        {
            foreach (var feed in m_Feeds)
            {
                if (feed.hand == hand)
                    return feed.hasHand && feed.IsPinching;
            }
            return false;
        }

        // From 0 with the fingertips open to 1 once they pinch; 0 while there's no hand. The
        // furthest along of the hands, so a caller watching one number sees the hand that is
        // actually pinching.
        public float PinchValue
        {
            get
            {
                var most = 0f;
                foreach (var feed in m_Feeds)
                {
                    if (feed.hasHand)
                        most = Mathf.Max(most, PinchValueOf(feed));
                }
                return most;
            }
        }

        float PinchValueOf(HandFeed feed) => feed.IsPinching
            ? 1f
            : Mathf.InverseLerp(m_OpenDistance, m_PinchDistance, feed.hand.pinchDistance);

        Transform TrackingSpace => m_TrackingSpace != null ? m_TrackingSpace : transform;

        void Awake()
        {
            if (m_Tracker == null)
            {
                Debug.LogError("[Hands] No tracker, so XR Hands has nothing to report");
                return;
            }
            // One feed per tracker slot, paired for good: the tracker's hands are stable objects,
            // so which feed follows which hand never has to be worked out again.
            foreach (var hand in m_Tracker.Hands)
                m_Feeds.Add(new HandFeed(hand, m_PinchDistance, m_ReleaseDistance));

            SubsystemManager.GetSubsystemDescriptors(s_Descriptors);
            foreach (var descriptor in s_Descriptors)
            {
                if (descriptor.id == CardboardHandProvider.Id)
                {
                    m_Subsystem = descriptor.Create();
                    break;
                }
            }
            if (m_Subsystem == null)
            {
                Debug.LogError($"[Hands] XR Hands has no {CardboardHandProvider.Id} subsystem");
                return;
            }
            // XRHandDevice takes its aim, pinch, poke and grip from the provider (see CardboardHandProvider)
            // only with common gestures. By default it works its own out from the joints and leaves the
            // aim and pinch empty.
            m_Subsystem.UpdateHandsConfiguration(new XRHandSubsystemConfiguration
            {
                xrHandDevicePoseSource = XRHandDevicePoseSource.CommonGestures,
            });
            m_Updater = new XRHandProviderUtility.SubsystemUpdater(m_Subsystem);
        }

        void OnEnable()
        {
            if (m_Subsystem == null)
                return;
            CardboardHandProvider.Feed = this;
            m_Subsystem.Start();
            m_Updater.Start();
            m_Subsystem.updatedHands += OnUpdatedHands;
            m_StatusStart = Time.unscaledTime;
            Debug.Log("[Hands] XR Hands running");
        }

        void OnDisable()
        {
            if (m_Subsystem == null)
                return;
            m_Subsystem.updatedHands -= OnUpdatedHands;
            m_Updater.Stop();
            m_Subsystem.Stop();
            if (CardboardHandProvider.Feed == this)
                CardboardHandProvider.Feed = null;
            foreach (var feed in m_Feeds)
                feed.Forget();
        }

        void OnDestroy()
        {
            m_Updater?.Destroy();
            m_Subsystem?.Destroy();
            m_Subsystem = null;
        }

        void Update()
        {
            foreach (var feed in m_Feeds)
                UpdateFeed(feed);
            ResolveSides();
            LogStatus();
        }

        void UpdateFeed(HandFeed feed)
        {
            if (!feed.hand.isTracking)
            {
                if (feed.hasHand)
                    Debug.Log($"[Hands] XR Hands lost the {feed.SideName} hand");
                feed.hasHand = false;
                // A pinch outlasts a brief miss: dropping it at once read as the fingers opening when the
                // hand came back, which let go of (and threw) what it held. Past HandInteractorRig's grace
                // the hand counts as lost, and the pinch goes.
                if (feed.lostSince < 0f)
                    feed.lostSince = Time.unscaledTime;
                if (Time.unscaledTime - feed.lostSince > k_PinchKeptSeconds)
                    feed.pinch.Reset();
                feed.turn.Reset();
                return;
            }
            feed.lostSince = -1f;

            // This hand's own results, not the tracker's total: that counts both hands, so one
            // hand's result would otherwise look like news to the other.
            if (feed.hand.results != feed.lastResult)
            {
                feed.lastResult = feed.hand.results;
                UpdateSide(feed);
                var landmarks = feed.hand.imageLandmarks;
                feed.turn.Update(PalmGesture.Facing(landmarks[PalmGesture.k_Wrist], landmarks[PalmGesture.k_IndexKnuckle],
                    landmarks[PalmGesture.k_PinkyKnuckle], feed.hand.handednessScore >= 0.5f), Time.unscaledTime);
            }
            UpdatePinch(feed);
        }

        // Two hands cannot both be the right hand, and the landmarker decides each one on its own,
        // so they can agree. Whichever is less sure of itself gives way, which keeps the hand the
        // model is confident about on the side it says.
        void ResolveSides()
        {
            HandFeed first = null;
            foreach (var feed in m_Feeds)
            {
                if (!feed.hasHand)
                    continue;
                if (first == null)
                {
                    first = feed;
                    continue;
                }
                var giving = HandFeed.MakeDistinct(feed, first, k_SideChangeMargin);
                if (giving == null)
                    continue;
                Debug.Log($"[Hands] Both hands read as the same side; the less sure one is now the " +
                          $"{giving.SideName} hand");
            }
        }

        // The fingertips' gap in the model's 3D hand shape decides the pinch, except that closed
        // fingers hide each other and collapse that shape: the tracker then reuses the last one it
        // trusted, whose fingertips are still together, and a hand that has opened goes on reading as
        // pinched. The gap in the image over the palm's width there comes straight from the 2D
        // landmarks, which survive that, so it ends a pinch on its own. It only ever opens a pinch,
        // never closes one, since it's the noisier of the two when the hand is edge-on.
        //
        // And only after a collapse. While the shape still fits, it's the better witness: pressing
        // the fingertips together hides one behind the other, and on the iPhone the image then
        // threw one away, reading 1.0 to 1.6 palm-widths open for up to 0.8 s at a time, while the
        // 3D shape kept them together. Every pinch lost dragging a cube was that.
        //
        // A pinch doesn't start while the hand is turning over (HandTurnGate): passing edge-on, the
        // shape squeezes the fingertips together for a few frames.
        void UpdatePinch(HandFeed feed)
        {
            var hand = feed.hand;
            var newResult = hand.results != feed.pinchResult;
            feed.pinchResult = hand.results;
            // Fingertips the model wasn't sure of say nothing about a pinch; the state holds.
            if (hand.tipsUnsure)
                return;
            if (!feed.pinch.IsPinched)
            {
                feed.openResults = 0;
                if (!hand.shapeFits)
                    return;
                // Near the image's edge the fingers are partly out of view and read as whatever
                // the model guesses, which on the phone was often a pinch: no pinch starts there.
                if (m_Tracker.EdgeDistanceOf(hand) < k_EdgeMargin)
                    return;
                // A flat shape has no depth to measure the gap by: the image's gap over the palm's
                // width is what it has, which is what the 3DoF pinch sensor reads too.
                var wouldClose = hand.flatShape ? hand.pinchRatio < m_CloseRatio : hand.pinchDistance < m_PinchDistance;
                if (wouldClose && feed.turn.IsTurning)
                {
                    if (!feed.loggedTurn)
                        Debug.Log($"[Hands] Fingertips {hand.pinchDistance * 100f:F1} cm apart while the " +
                                  $"{feed.SideName} hand turned over; not a pinch");
                    feed.loggedTurn = true;
                }
                else
                {
                    feed.pinch.Update(hand.flatShape ? (wouldClose ? 0f : float.MaxValue) : hand.pinchDistance);
                }
                if (!feed.turn.IsTurning)
                    feed.loggedTurn = false;
                return;
            }

            // Pinched: whether this result says the fingers have opened, by the 3D shape while it fits,
            // by the image's gap once it has collapsed.
            var byShape = hand.shapeFits && !hand.flatShape;
            var opens = byShape ? hand.pinchDistance > m_ReleaseDistance : hand.pinchRatio > m_OpenRatio;
            if (byShape && !opens && hand.pinchRatio > m_OpenRatio)
                m_IgnoredOpens++;
            if (!opens)
            {
                feed.openResults = 0;
                feed.loggedEdge = false;
                return;
            }
            if (!newResult)
                return;
            // Near the image's edge the fingers are often partly out of view, and read open as the hand
            // leaves it: that's a hand being lost, not let go, so the pinch holds. Either the hand comes
            // back into view or it's lost (and what it held stays where it was: CubePhysics).
            var edge = m_Tracker.EdgeDistanceOf(hand);
            if (edge < k_EdgeMargin)
            {
                if (!feed.loggedEdge)
                    Debug.Log($"[Hands] The {feed.SideName} hand's fingers read open {edge * 100f:F0}% from " +
                              "the image's edge; holding the pinch");
                feed.loggedEdge = true;
                feed.openResults = 0;
                return;
            }
            // And only once it lasts: a single result can be a glitch.
            if (++feed.openResults < k_OpenResults)
                return;
            if (!hand.shapeFits)
                Debug.Log($"[Hands] The {feed.SideName} hand's fingers opened to {hand.pinchRatio:F2} of the " +
                          "palm's width; ending the pinch, whose 3D shape had collapsed");
            feed.pinch.Reset();
            feed.openResults = 0;
        }

        void UpdateSide(HandFeed feed)
        {
            // MediaPipe documents its handedness as if the image were mirrored, as a selfie camera's
            // is, which would swap the rear camera's hands. On the phone it reads them the right way
            // round: swapping them put the other hand's mesh, turned over, on the real hand.
            var right = feed.hand.handednessScore;
            if (!feed.hasHand)
            {
                feed.hasHand = true;
                feed.rightChance = right;
                feed.isRight = right >= 0.5f;
                Debug.Log($"[Hands] XR Hands found a {feed.SideName} hand (chance of a right hand {right:F2})");
                return;
            }
            feed.rightChance = Mathf.Lerp(feed.rightChance, right, k_HandednessRate);
            if (feed.isRight ? feed.rightChance < 0.5f - k_SideChangeMargin : feed.rightChance > 0.5f + k_SideChangeMargin)
            {
                feed.isRight = !feed.isRight;
                Debug.Log($"[Hands] XR Hands now reads it as a {feed.SideName} hand " +
                          $"(chance of a right hand {feed.rightChance:F2})");
            }
        }

        HandFeed Find(Handedness handedness)
        {
            foreach (var feed in m_Feeds)
            {
                if (feed.hasHand && feed.Side == handedness)
                    return feed;
            }
            return null;
        }

        // Each side's joints in the tracking space, for the provider; false while that side has no
        // hand. The provider asks for both sides every update.
        internal bool TryGetJoints(Handedness handedness, out Pose[] joints)
        {
            joints = null;
            var feed = Find(handedness);
            if (feed == null || !feed.hand.isTracking)
                return false;
            joints = feed.joints;
            var space = TrackingSpace;
            var world = feed.hand.joints;
            for (var i = 0; i < feed.landmarks.Length; i++)
                feed.landmarks[i] = space.InverseTransformPoint(world[i]);
            HandSkeleton.Build(feed.landmarks, feed.isRight, feed.joints);
            return true;
        }

        // The provider asks for these after the joints (TryGetJoints), in the same update.
        internal bool TryGetPose(Handedness handedness, PoseKind kind, out Pose pose)
        {
            pose = Pose.identity;
            var feed = Find(handedness);
            if (feed == null)
                return false;
            switch (kind)
            {
                case PoseKind.Grip:
                    pose = feed.joints[HandSkeleton.Palm];
                    break;
                case PoseKind.Poke:
                    pose = feed.joints[HandSkeleton.IndexTip];
                    break;
                default:
                    var space = TrackingSpace;
                    var fingertips = (feed.landmarks[HandGeometry.ThumbTip] + feed.landmarks[HandGeometry.IndexTip]) / 2f;
                    var eyes = space.InverseTransformPoint(m_Eyes.position);
                    pose = new Pose(fingertips, Quaternion.LookRotation(fingertips - eyes, space.InverseTransformDirection(m_Eyes.up)));
                    break;
            }
            return true;
        }

        // The pinch value runs from 0 with the fingertips open to 1 once they pinch.
        internal bool TryGetPinch(Handedness handedness, out float value, out bool pinched)
        {
            value = 0f;
            pinched = false;
            var feed = Find(handedness);
            if (feed == null)
                return false;
            pinched = feed.IsPinching;
            value = PinchValueOf(feed);
            return true;
        }

        // What XR Hands and its input device report, to check them against the tracker. One line
        // per hand that is up, so two hands do not have to be told apart by guesswork.
        void LogStatus()
        {
            if (Time.unscaledTime - m_StatusStart < k_StatusSeconds)
                return;
            m_StatusStart = Time.unscaledTime;
            var any = false;
            foreach (var feed in m_Feeds)
            {
                if (!feed.hasHand)
                    continue;
                any = true;
                Debug.Log(Describe(feed));
            }
            if (!any)
                Debug.Log($"[Hands] XR Hands has no hand; {m_EarlyUpdates} early and " +
                          $"{m_BeforeRenderUpdates} before-render updates");
            m_EarlyUpdates = m_BeforeRenderUpdates = m_IgnoredOpens = 0;
        }

        string Describe(HandFeed feed)
        {
            var hand = feed.isRight ? m_Subsystem.rightHand : m_Subsystem.leftHand;
            var common = feed.isRight ? m_Subsystem.rightHandCommonGestures : m_Subsystem.leftHandCommonGestures;
            var device = feed.isRight ? XRHandDevice.rightHand : XRHandDevice.leftHand;
            var wrist = TrackingSpace.TransformPoint(hand.rootPose.position);
            var wristOff = Vector3.Distance(wrist, feed.hand.joints[0]);
            // The aim at each step on its way to input actions: this feed, XR Hands, its input device.
            var feedAim = TryGetPose(feed.Side, PoseKind.Aim, out var aim) ? $"{aim.rotation.eulerAngles:F0}" : "none";
            var subsystemAim = common != null && common.TryGetAimPose(out var commonAim) ? $"{commonAim.rotation.eulerAngles:F0}" : "none";
            var status = $"[Hands] XR Hands {feed.SideName} hand: tracked {hand.isTracked}, wrist {wristOff * 100f:F1} cm from the tracker's, " +
                         $"chance of a right hand {feed.rightChance:F2}; {m_EarlyUpdates} early and {m_BeforeRenderUpdates} before-render " +
                         $"updates; aim from the feed {feedAim}, in XR Hands {subsystemAim}";
            if (device != null)
                status += $", on the device {device.aimRotation.ReadValue().eulerAngles:F0} (tracking {device.aimTrackingState.ReadValue()}, " +
                          $"device tracked {device.isTracked.isPressed}); device pinch {device.pinchValue.ReadValue():F2} " +
                          $"(touched {device.pinchTouched.isPressed})";
            else
                status += "; no XRHandDevice";
            status += $"; {m_IgnoredOpens} frames the image read open fingers while the 3D shape held the pinch";
            return status;
        }

        void OnUpdatedHands(XRHandSubsystem subsystem, XRHandSubsystem.UpdateSuccessFlags flags, XRHandSubsystem.UpdateType updateType)
        {
            if (updateType == XRHandSubsystem.UpdateType.Dynamic)
                m_EarlyUpdates++;
            else
                m_BeforeRenderUpdates++;
        }
    }
}
