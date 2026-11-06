using Afterglow.Hands;
using NUnit.Framework;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    // Finding more than one palm in a detector result.
    //
    // The detector fires several neighbouring anchors on a single hand, so the interesting
    // question is never "did it find something" but "is the second thing it found a second hand,
    // or the side of the first one". Getting that wrong gives the user a phantom hand, which is
    // worse than only ever tracking one.
    public class PalmDecoderTests
    {
        const int k_Anchors = PalmDecoder.AnchorCount;
        const int k_Values = PalmDecoder.ValuesPerAnchor;
        const float k_Size = PalmDecoder.InputSize;

        float[] m_Boxes;
        float[] m_Scores;
        Vector2[] m_Anchors;
        bool[] m_Suppressed;

        [SetUp]
        public void SetUp()
        {
            m_Boxes = new float[k_Anchors * k_Values];
            m_Scores = new float[k_Anchors];
            m_Anchors = PalmDecoder.CreateAnchors();
            m_Suppressed = new bool[k_Anchors];
            // A logit well below any threshold used here, so only the anchors a test sets matter.
            for (var i = 0; i < k_Anchors; i++)
                m_Scores[i] = -12f;
        }

        // Puts a palm on one anchor: a box of `size` centred on `center`, both 0-1 across the
        // detector's square input, with the score as a probability.
        void Place(int anchor, Vector2 center, float size, float score)
        {
            m_Scores[anchor] = Logit(score);
            var o = anchor * k_Values;
            var offset = (center - m_Anchors[anchor]) * k_Size;
            m_Boxes[o] = offset.x;
            m_Boxes[o + 1] = offset.y;
            m_Boxes[o + 2] = size * k_Size;
            m_Boxes[o + 3] = size * k_Size;
            // The wrist below the centre and the middle knuckle above it, so the hand points up.
            m_Boxes[o + 4] = offset.x;
            m_Boxes[o + 5] = offset.y + size * k_Size / 2f;
            m_Boxes[o + 8] = offset.x;
            m_Boxes[o + 9] = offset.y - size * k_Size / 2f;
        }

        static float Logit(float p) => Mathf.Log(p / (1f - p));

        // An anchor whose cell centre is nearest a point, so a test can place a palm where the
        // detector would actually have seen one.
        int NearestAnchor(Vector2 center)
        {
            var best = 0;
            for (var i = 1; i < k_Anchors; i++)
            {
                if (Vector2.Distance(m_Anchors[i], center) < Vector2.Distance(m_Anchors[best], center))
                    best = i;
            }
            return best;
        }

        [Test]
        public void TwoHandsApartAreBothFound()
        {
            var left = new Vector2(0.25f, 0.5f);
            var right = new Vector2(0.75f, 0.5f);
            Place(NearestAnchor(left), left, 0.2f, 0.9f);
            Place(NearestAnchor(right), right, 0.2f, 0.8f);

            var palms = new Palm[2];
            var found = PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, palms);

            Assert.AreEqual(2, found);
            // Best first.
            Assert.Greater(palms[0].score, palms[1].score);
            Assert.AreEqual(left.x, palms[0].center.x, 0.02f, "the stronger palm");
            Assert.AreEqual(right.x, palms[1].center.x, 0.02f, "the weaker palm");
        }

        [Test]
        public void OneHandSeenByManyAnchorsIsStillOneHand()
        {
            // What the detector really does: a cluster of neighbouring anchors all firing on the
            // same hand, with slightly different boxes and scores.
            var center = new Vector2(0.5f, 0.5f);
            var anchor = NearestAnchor(center);
            for (var i = -3; i <= 3; i++)
            {
                var nudged = center + new Vector2(i * 0.01f, i * 0.008f);
                Place(anchor + i, nudged, 0.22f, 0.9f - Mathf.Abs(i) * 0.05f);
            }

            var palms = new Palm[4];
            var found = PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, palms);

            Assert.AreEqual(1, found, "a cluster on one hand must collapse to one palm");
            Assert.AreEqual(0.9f, palms[0].score, 0.01f, "and it keeps the best of them");
        }

        [Test]
        public void TwoHandsTouchingAreStillTwoHands()
        {
            // Hands held close but not overlapping much: a quarter of the input apart with boxes
            // a fifth wide, so the boxes barely meet. Both have to survive, or the second hand
            // disappears whenever the user brings their hands together.
            var a = new Vector2(0.40f, 0.5f);
            var b = new Vector2(0.62f, 0.5f);
            Place(NearestAnchor(a), a, 0.2f, 0.9f);
            Place(NearestAnchor(b), b, 0.2f, 0.85f);

            var palms = new Palm[2];
            var found = PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, palms);

            Assert.AreEqual(2, found, $"overlap was {PalmDecoder.Overlap(palms[0], palms[1]):F2}");
        }

        [Test]
        public void NothingAboveTheThresholdFindsNothing()
        {
            var center = new Vector2(0.5f, 0.5f);
            Place(NearestAnchor(center), center, 0.2f, 0.3f);

            var palms = new Palm[2];
            Assert.AreEqual(0, PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, palms));
        }

        [Test]
        public void ItNeverWritesPastWhatItWasGiven()
        {
            for (var i = 0; i < 6; i++)
            {
                var center = new Vector2(0.1f + i * 0.15f, 0.5f);
                Place(NearestAnchor(center), center, 0.08f, 0.9f);
            }

            var one = new Palm[1];
            Assert.AreEqual(1, PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, one));
            var two = new Palm[2];
            Assert.AreEqual(2, PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, two));
        }

        [Test]
        public void TheScoresAreLeftAsTheyWereFound()
        {
            // The caller reuses this buffer and reads it elsewhere, so suppression must not be
            // done by writing over it.
            var left = new Vector2(0.25f, 0.5f);
            var right = new Vector2(0.75f, 0.5f);
            Place(NearestAnchor(left), left, 0.2f, 0.9f);
            Place(NearestAnchor(right), right, 0.2f, 0.8f);
            var before = (float[])m_Scores.Clone();

            PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, new Palm[2]);

            Assert.AreEqual(before, m_Scores);
        }

        [Test]
        public void TheFirstPalmIsTheOneTheOldPathWouldHavePicked()
        {
            // So that turning two-hand tracking on cannot change which hand a one-handed user
            // gets: whatever DecodeAll puts first has to be exactly TryDecodeBest's answer.
            var strong = new Vector2(0.7f, 0.3f);
            var weak = new Vector2(0.2f, 0.8f);
            Place(NearestAnchor(strong), strong, 0.25f, 0.95f);
            Place(NearestAnchor(weak), weak, 0.18f, 0.6f);

            Assert.IsTrue(PalmDecoder.TryDecodeBest(m_Boxes, m_Scores, m_Anchors, 0.5f, out var best));
            var palms = new Palm[2];
            Assert.AreEqual(2, PalmDecoder.DecodeAll(m_Boxes, m_Scores, m_Anchors, 0.5f, m_Suppressed, palms));

            Assert.AreEqual(best.score, palms[0].score, 1e-6f);
            Assert.AreEqual(best.center, palms[0].center);
            Assert.AreEqual(best.size, palms[0].size);
            Assert.AreEqual(best.wrist, palms[0].wrist);
            Assert.AreEqual(best.middleKnuckle, palms[0].middleKnuckle);
        }

        [Test]
        public void OverlapIsOneForTheSameBoxAndZeroWhenApart()
        {
            var a = new Palm { center = new Vector2(0.5f, 0.5f), size = new Vector2(0.2f, 0.2f) };
            var apart = new Palm { center = new Vector2(0.9f, 0.9f), size = new Vector2(0.2f, 0.2f) };
            Assert.AreEqual(1f, PalmDecoder.Overlap(a, a), 1e-6f);
            Assert.AreEqual(0f, PalmDecoder.Overlap(a, apart), 1e-6f);
            // Half-overlapping in x, fully in y: an intersection of 1/2 against a union of 3/2.
            var half = new Palm { center = new Vector2(0.6f, 0.5f), size = new Vector2(0.2f, 0.2f) };
            Assert.AreEqual(1f / 3f, PalmDecoder.Overlap(a, half), 1e-5f);
        }
    }
}
