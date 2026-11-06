using System;
using System.Runtime.InteropServices;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using UnityEngine;

namespace Afterglow.Hands
{
    // Apple's Vision hand pose (Plugins/iOS/AfterglowHandPose.mm): 21 joints per hand for up to
    // two hands from a camera image, found on the Neural Engine. HandTracker gives it each image
    // and takes the joints back as the landmarks in the image, in MediaPipe's order, with a
    // confidence per joint and which hand it is. Off iOS there is no Vision and Supported says so.
    public static class VisionHandPose
    {
        public const int MaxHands = 2;
        const int k_HandFloats = 2 + HandGeometry.JointCount * 3;
        const int k_ResultFloats = 1 + MaxHands * k_HandFloats;

        public enum Chirality { Unknown = 0, Left = 1, Right = 2 }

        // One hand as Vision saw it.
        public sealed class Hand
        {
            public Chirality chirality;
            public float confidence;
            public readonly Vector2[] landmarks = new Vector2[HandGeometry.JointCount];
            public readonly float[] confidences = new float[HandGeometry.JointCount];

            // The joints' mean confidence: how sure Vision is of the whole hand.
            public float MeanConfidence
            {
                get
                {
                    var sum = 0f;
                    foreach (var c in confidences)
                        sum += c;
                    return sum / confidences.Length;
                }
            }
        }

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        static readonly float[] s_Result = new float[k_ResultFloats];

        // Hands the request in flight is working on, or 0 when nothing is.
        public static int Pending { get; private set; }

        // Starts a request on an RGBA image whose first row is the top. `orientation` is the
        // CGImagePropertyOrientation (1 up, 3 upside down, 6 and 8 the quarter turns) that makes
        // the image upright for the model. Returns the request's number, or 0 if one is still
        // running: the image is simply skipped, since the next one is on its way.
        public static int Submit(NativeArray<byte> rgba, int width, int height, int orientation)
        {
            if (!Supported || !rgba.IsCreated || rgba.Length < width * height * 4)
                return 0;
#if UNITY_IOS && !UNITY_EDITOR
            int sequence;
            unsafe
            {
                sequence = Afterglow_HandPoseSubmit((byte*)NativeArrayUnsafeUtility.GetUnsafeReadOnlyPtr(rgba), width, height, width * 4, orientation);
            }
            if (sequence != 0)
                Pending = sequence;
            return sequence;
#else
            return 0;
#endif
        }

        // The result waiting, if any: fills `hands` (which has MaxHands entries) with landmarks in
        // pixels of the image as given (first row the top), and says how many hands were found,
        // -1 if the request failed, or returns false when nothing is ready. `ms` is how long the
        // request took. width, height and orientation are the submitted image's.
        public static bool TryTake(Hand[] hands, int width, int height, int orientation, out int count, out int sequence, out float ms)
        {
            count = 0;
            sequence = 0;
            ms = 0f;
#if UNITY_IOS && !UNITY_EDITOR
            sequence = Afterglow_HandPosePoll(s_Result, s_Result.Length, out ms);
            if (sequence == 0)
                return false;
            Pending = 0;
            count = Parse(s_Result, hands, width, height, orientation);
            return true;
#else
            return false;
#endif
        }

        // Reads the plugin's flat result into hands, with the landmarks turned into pixels of the
        // image as given; pure so it can be tested.
        public static int Parse(float[] result, Hand[] hands, int width, int height, int orientation)
        {
            var count = Mathf.RoundToInt(result[0]);
            if (count < 0)
                return -1;
            count = Mathf.Min(count, Mathf.Min(MaxHands, hands.Length));
            for (var h = 0; h < count; h++)
            {
                var at = 1 + h * k_HandFloats;
                var hand = hands[h] ??= new Hand();
                hand.chirality = (Chirality)Mathf.Clamp(Mathf.RoundToInt(result[at]), 0, 2);
                hand.confidence = result[at + 1];
                for (var i = 0; i < HandGeometry.JointCount; i++)
                {
                    var j = at + 2 + i * 3;
                    hand.landmarks[i] = ToImage(result[j], result[j + 1], width, height, orientation);
                    hand.confidences[i] = result[j + 2];
                }
            }
            return count;
        }

        // A point Vision gives (normalized, origin bottom left, in the image as oriented for the
        // request) as pixels of the image as given, first row the top, width x height. The
        // orientation is the CGImagePropertyOrientation the request was told: how the given image
        // has to be turned to be upright, so a result in the upright image is turned back. 1 is
        // upright already; 3 upside down; 6 needs a quarter turn clockwise, 8 anticlockwise; 2, 4,
        // 5 and 7 are those with a mirror.
        public static Vector2 ToImage(float nx, float ny, int width, int height, int orientation)
        {
            float x, y;
            switch (orientation)
            {
                case 2: x = (1f - nx) * width; y = (1f - ny) * height; break;
                case 3: x = (1f - nx) * width; y = ny * height; break;
                case 4: x = nx * width; y = ny * height; break;
                // Turned a quarter: the upright image is height wide and width tall, and a point's
                // place along its width is a place along the given image's height.
                case 5: x = (1f - ny) * width; y = nx * height; break;
                case 6: x = (1f - ny) * width; y = (1f - nx) * height; break;
                case 7: x = ny * width; y = (1f - nx) * height; break;
                case 8: x = ny * width; y = nx * height; break;
                default: x = nx * width; y = (1f - ny) * height; break;
            }
            return new Vector2(x, y);
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern unsafe int Afterglow_HandPoseSubmit(byte* rgba, int width, int height, int stride, int orientation);
        [DllImport("__Internal")] static extern int Afterglow_HandPosePoll(float[] result, int capacity, out float ms);
#endif
    }
}
