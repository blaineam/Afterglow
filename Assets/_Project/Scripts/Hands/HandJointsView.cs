using CardboardXR.Stereo;
using UnityEngine;

namespace CardboardXR.Hands
{
    // Shows each tracked hand as a simple skeleton, colored by finger: its 21 joints as small spheres and
    // the bones between them as thin rods. It follows only the joints' positions, so it can't twist the
    // way a skinned hand mesh posed from the joints' noisy rotations did.
    //
    // One skeleton per hand the tracker can follow, built up front and shown or hidden as that hand
    // comes and goes: building one when a hand appears would allocate and compile its material in
    // the middle of tracking, which is the worst moment for a hitch.
    // It hides in passthrough, where the real hand is already in the picture: the one camera gives both
    // eyes the same flat image at one distance, so a skeleton drawn in 3D over it doesn't fuse. The ray
    // cursor, which sits on what the hand points at, is the feedback there.
    public class HandJointsView : MonoBehaviour
    {
        // URP's main color property.
        static readonly int k_BaseColor = Shader.PropertyToID("_BaseColor");
        // After the transparent queue, which holds the room boundary's grid, so the grid, which
        // ignores depth, never covers the hand.
        const int k_RenderQueue = 3150;
        // MediaPipe's hand connections: each finger from its base, and across the knuckles.
        static readonly (int from, int to)[] k_Bones =
        {
            (0, 1), (1, 2), (2, 3), (3, 4),
            (0, 5), (5, 6), (6, 7), (7, 8),
            (9, 10), (10, 11), (11, 12),
            (13, 14), (14, 15), (15, 16),
            (0, 17), (17, 18), (18, 19), (19, 20),
            (5, 9), (9, 13), (13, 17),
        };

        [SerializeField] HandTracker m_Tracker;
        [Tooltip("Optional: the thumb and index fingertips grow while it sees a pinch.")]
        [SerializeField] HandSubsystemFeed m_Feed;
        [Tooltip("The hand hides while this shows the camera image.")]
        [SerializeField] PassthroughController m_Passthrough;
        [SerializeField] Material m_Material;
        [SerializeField] float m_JointSize = 0.012f;
        [SerializeField] float m_BoneWidth = 0.006f;
        [SerializeField] float m_PinchedTipScale = 2f;

        // One per hand the tracker follows, in the same order as its own.
        Skeleton[] m_Skeletons;

        // The parts of one hand's skeleton, and whether they are currently drawn.
        class Skeleton
        {
            public Transform[] joints;
            public Transform[] bones;
            public bool shown = true;
        }

        void Start()
        {
            if (m_Tracker == null)
            {
                Debug.LogError("[Hands] No tracker, so there are no hands to draw");
                m_Skeletons = new Skeleton[0];
                return;
            }
            // Set here rather than on the saved material, where URP resets the queue.
            var material = new Material(m_Material) { renderQueue = k_RenderQueue };
            var block = new MaterialPropertyBlock();
            m_Skeletons = new Skeleton[m_Tracker.Hands.Count];
            for (var h = 0; h < m_Skeletons.Length; h++)
            {
                var skeleton = new Skeleton
                {
                    joints = new Transform[HandGeometry.JointCount],
                    bones = new Transform[k_Bones.Length],
                };
                for (var i = 0; i < skeleton.joints.Length; i++)
                {
                    skeleton.joints[i] = CreatePart(PrimitiveType.Sphere, $"Hand {h} joint {i}", material, block, FingerColor(i));
                    skeleton.joints[i].localScale = Vector3.one * m_JointSize;
                }
                for (var i = 0; i < skeleton.bones.Length; i++)
                {
                    var (from, to) = k_Bones[i];
                    // A finger's bones take its color; the ones across the knuckles are white.
                    var color = to - from == 1 || from == 0 ? FingerColor(to) : Color.white;
                    skeleton.bones[i] = CreatePart(PrimitiveType.Cylinder, $"Hand {h} bone {from}-{to}", material, block, color);
                }
                m_Skeletons[h] = skeleton;
                SetShown(skeleton, false);
            }
        }

        Transform CreatePart(PrimitiveType type, string partName, Material material, MaterialPropertyBlock block, Color color)
        {
            var part = GameObject.CreatePrimitive(type);
            part.name = partName;
            Destroy(part.GetComponent<Collider>());
            part.transform.SetParent(transform, false);
            var renderer = part.GetComponent<MeshRenderer>();
            renderer.sharedMaterial = material;
            renderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            renderer.receiveShadows = false;
            block.SetColor(k_BaseColor, color);
            renderer.SetPropertyBlock(block);
            return part.transform;
        }

        void LateUpdate()
        {
            var hidden = m_Passthrough != null && m_Passthrough.IsOn;
            var hands = m_Tracker.Hands;
            for (var h = 0; h < m_Skeletons.Length && h < hands.Count; h++)
                Draw(m_Skeletons[h], hands[h], hidden);
        }

        void Draw(Skeleton skeleton, TrackedHand hand, bool hidden)
        {
            SetShown(skeleton, hand.isTracking && !hidden);
            if (!skeleton.shown)
                return;
            var joints = hand.joints;
            for (var i = 0; i < skeleton.joints.Length; i++)
                skeleton.joints[i].position = joints[i];
            // Whether this hand is the one pinching, rather than whether either is: the fingertips
            // of a hand resting at your side should not swell because the other hand pinched.
            var pinching = m_Feed != null && m_Feed.IsPinchingWith(hand);
            var tipSize = m_JointSize * (pinching ? m_PinchedTipScale : 1f);
            skeleton.joints[HandGeometry.ThumbTip].localScale =
                skeleton.joints[HandGeometry.IndexTip].localScale = Vector3.one * tipSize;

            // A cylinder is two units long along its y axis.
            for (var i = 0; i < skeleton.bones.Length; i++)
            {
                var (from, to) = k_Bones[i];
                var along = joints[to] - joints[from];
                var bone = skeleton.bones[i];
                bone.position = (joints[from] + joints[to]) / 2f;
                bone.rotation = along.sqrMagnitude > 1e-10f ? Quaternion.FromToRotation(Vector3.up, along) : Quaternion.identity;
                bone.localScale = new Vector3(m_BoneWidth, along.magnitude / 2f, m_BoneWidth);
            }
        }

        static void SetShown(Skeleton skeleton, bool shown)
        {
            if (shown == skeleton.shown)
                return;
            skeleton.shown = shown;
            foreach (var joint in skeleton.joints)
                joint.gameObject.SetActive(shown);
            foreach (var bone in skeleton.bones)
                bone.gameObject.SetActive(shown);
        }

        // White wrist, then thumb, index, middle, ring and little finger in red, orange, yellow,
        // green and blue.
        static Color FingerColor(int joint) => joint == 0
            ? Color.white
            : ((joint - 1) / 4) switch
            {
                0 => Color.red,
                1 => new Color(1f, 0.5f, 0f),
                2 => Color.yellow,
                3 => Color.green,
                _ => new Color(0.2f, 0.4f, 1f),
            };
    }
}
