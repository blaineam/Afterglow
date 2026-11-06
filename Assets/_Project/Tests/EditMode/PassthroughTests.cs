using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    public class PassthroughTests
    {
        [Test]
        public void CroppedDisplayTransform_WidensToTheWholeImage()
        {
            // A 4:3 image on a wider screen: all of its width, the middle 60% of its height.
            var display = Transform(new Vector2(1f, 0f), new Vector2(0f, 0.6f), new Vector2(0f, 0.2f));
            Assert.IsTrue(PassthroughController.TryWidenDisplayTransform(display, out var widened, out var min, out var max));

            AssertClose(new Vector2(0f, -1f / 3f), min);
            AssertClose(new Vector2(1f, 4f / 3f), max);
            AssertClose(new Vector2(0f, 0f), Apply(widened, new Vector2(0f, 0f)));
            AssertClose(new Vector2(1f, 1f), Apply(widened, new Vector2(1f, 1f)));
        }

        [Test]
        public void RotatedDisplayTransform_StillCoversEveryCorner()
        {
            // The image turned a quarter turn and cropped: tex = (0.2 + 0.6 v, 1 - u).
            var display = Transform(new Vector2(0f, -1f), new Vector2(0.6f, 0f), new Vector2(0.2f, 1f));
            Assert.IsTrue(PassthroughController.TryWidenDisplayTransform(display, out var widened, out _, out _));

            var corners = new HashSet<Vector2Int>();
            foreach (var screen in new[] { Vector2.zero, Vector2.right, Vector2.up, Vector2.one })
            {
                var texture = Apply(widened, screen);
                var corner = new Vector2Int(Mathf.RoundToInt(texture.x), Mathf.RoundToInt(texture.y));
                AssertClose(corner, texture);
                corners.Add(corner);
            }
            Assert.AreEqual(4, corners.Count, "each screen corner lands on a different image corner");
        }

        // The ARCore shader's convention: tex = u * (m00, m01) + v * (m10, m11) + (m20, m21).
        static Matrix4x4 Transform(Vector2 perU, Vector2 perV, Vector2 offset)
        {
            var matrix = Matrix4x4.identity;
            matrix.m00 = perU.x;
            matrix.m01 = perU.y;
            matrix.m10 = perV.x;
            matrix.m11 = perV.y;
            matrix.m20 = offset.x;
            matrix.m21 = offset.y;
            return matrix;
        }

        static Vector2 Apply(Matrix4x4 m, Vector2 uv) =>
            new(uv.x * m.m00 + uv.y * m.m10 + m.m20, uv.x * m.m01 + uv.y * m.m11 + m.m21);

        static void AssertClose(Vector2 expected, Vector2 actual) =>
            Assert.That((actual - expected).magnitude, Is.LessThan(1e-5f), $"expected {expected}, got {actual}");
    }

    // Reprojecting the camera image, which is what the shader does per pixel.
    //
    // The image shown is 45-100 ms old and the head has moved since. The quad it is drawn on is only
    // a surface; PassthroughController.TryImageUv decides what each of its pixels shows, from the
    // direction that pixel looks in. These tests pin the two properties that make the picture hold
    // still: it does not matter how far away the thing on that line of sight is, and it does not
    // matter where the position filter thinks the head is.
    public class PassthroughReprojectionTests
    {
        // What the camera covers in its own axes at unit distance: a 4:3 image about 68 x 54 degrees
        // across, with its center a little off the optical axis, as a real one is.
        static readonly Vector2 k_Center = new(0.03f, -0.02f);
        static readonly Vector2 k_Size = new(1.36f, 1.02f);
        // The pose the image was taken from: off the origin and turned, so that nothing passes by
        // accident through being at the identity.
        static readonly Vector3 k_CapturePosition = new(0.2f, 1.5f, -0.4f);
        static readonly Quaternion k_CaptureRotation = Quaternion.Euler(-12f, 35f, 7f);

        static Matrix4x4 CaptureFromWorld() =>
            Matrix4x4.TRS(k_CapturePosition, k_CaptureRotation, Vector3.one).inverse;

        static Vector2 Uv(Vector3 eye, Vector3 worldPoint)
        {
            Assert.IsTrue(PassthroughController.TryImageUv(CaptureFromWorld(), eye, worldPoint,
                k_Center, k_Size, out var uv), "expected the point to map");
            return uv;
        }

        [Test]
        public void TheOpticalAxisLandsOnTheCenterTheCameraReported()
        {
            // Straight out of the camera, from the point it was taken from: the middle of the image
            // is wherever the frustum's center says it is, not the middle of the texture.
            var ahead = k_CapturePosition + k_CaptureRotation * (Vector3.forward * 5f);
            var uv = Uv(k_CapturePosition, ahead);
            AssertClose(new Vector2(0.5f - k_Center.x / k_Size.x, 0.5f - k_Center.y / k_Size.y), uv);
        }

        [Test]
        public void EveryPointAlongOneLineOfSightLandsOnTheSamePixel()
        {
            // Depth drops out of the mapping. This is what lets the quad sit wherever it likes --
            // PassthroughHandFocus moves it between 2 m and 0.3 m -- without touching the picture.
            var eye = k_CapturePosition;
            var direction = (k_CaptureRotation * new Vector3(0.4f, -0.25f, 1f)).normalized;
            var near = Uv(eye, eye + direction * 0.25f);
            foreach (var distance in new[] { 0.3f, 1f, 2f, 7f, 60f })
                AssertClose(near, Uv(eye, eye + direction * distance));
        }

        [Test]
        public void WhereTheFilterThinksTheHeadIsCannotMoveThePicture()
        {
            // The fix, stated: the eye is a centimeter or two from the point the image was taken
            // from, because the image is old and the position is a prediction, and tilting the head
            // makes that worse by leaking gravity into the filter. None of it reaches the picture.
            var direction = k_CaptureRotation * new Vector3(-0.5f, 0.3f, 1f);
            var wanted = Uv(k_CapturePosition, k_CapturePosition + direction);
            foreach (var slip in new[]
                     {
                         new Vector3(0.02f, 0f, 0f), new Vector3(0f, -0.015f, 0.01f),
                         new Vector3(-0.07f, 0.04f, -0.06f), new Vector3(0.5f, 0.5f, 0.5f),
                     })
            {
                var eye = k_CapturePosition + slip;
                // The same line of sight out of the moved eye, at any depth.
                AssertClose(wanted, Uv(eye, eye + direction * 3.5f));
            }
        }

        [Test]
        public void TurningTheHeadCarriesThePictureWithTheRoom()
        {
            // A fixed feature of the room, and the pixel that happens to look at it after the head
            // has turned by some amount. However far it has turned, that pixel shows the same place
            // in the image: the picture is pinned to the room, not to the screen.
            var eye = k_CapturePosition;
            var feature = eye + k_CaptureRotation * new Vector3(1.1f, 0.35f, 4f);
            var wanted = Uv(eye, feature);
            foreach (var turn in new[]
                     {
                         Quaternion.Euler(0f, 25f, 0f), Quaternion.Euler(14f, -20f, 0f),
                         Quaternion.Euler(0f, 0f, 30f), Quaternion.Euler(-12f, 30f, 18f),
                     })
            {
                // How far the head has turned since the image was taken, so the feature is still in
                // front of it. The quad is square to the view at `quad` meters, and the pixel looking
                // at the feature sits where that line of sight crosses the quad -- somewhere quite
                // different on it for each turn.
                const float quad = 1.3f;
                var head = k_CaptureRotation * turn;
                var inHead = Quaternion.Inverse(head) * (feature - eye);
                Assert.Greater(inHead.z, 0f, "the test needs the feature in front of the turned head");
                var onQuad = eye + head * (inHead * (quad / inHead.z));
                AssertClose(wanted, Uv(eye, onQuad));
            }
        }

        [Test]
        public void TheFlatScreenItReplacedMovedWithThePositionEstimate()
        {
            // The same feature, mapped the way it was before: a quad rigidly attached to the capture
            // pose, covering the camera's frustum at the distance PassthroughHandFocus had pulled it
            // to, with the pixel's own place on that quad deciding what it shows. Two centimeters of
            // position error swings a wall several degrees, which is the stretch and pull.
            const float plane = 0.3f;
            var feature = k_CapturePosition + k_CaptureRotation * new Vector3(0.8f, 0.2f, 3f);
            var still = FlatScreenUv(k_CapturePosition, feature, plane);
            var moved = FlatScreenUv(k_CapturePosition + new Vector3(0.02f, 0f, 0f), feature, plane);

            // In degrees across the image, so the number means something: k_Size is a tangent.
            var swing = Mathf.Atan((moved.x - still.x) * k_Size.x) * Mathf.Rad2Deg;
            Assert.Greater(Mathf.Abs(swing), 2f, $"expected a visible swing, got {swing:F2} deg");

            // And with the plane out at 2 m the same error is small, which is why it only became
            // unbearable once a raised hand pulled the plane in.
            var far = FlatScreenUv(k_CapturePosition, feature, 2f);
            var farMoved = FlatScreenUv(k_CapturePosition + new Vector3(0.02f, 0f, 0f), feature, 2f);
            Assert.Less(Mathf.Abs(Mathf.Atan((farMoved.x - far.x) * k_Size.x) * Mathf.Rad2Deg), 0.5f);

            // Reprojecting by direction has neither: the eye's position is not in the mapping.
            AssertClose(Uv(k_CapturePosition, feature),
                Uv(k_CapturePosition + new Vector3(0.02f, 0f, 0f),
                    k_CapturePosition + new Vector3(0.02f, 0f, 0f) + (feature - k_CapturePosition)));
        }

        // The model this replaced. The quad hangs on the capture pose at `plane` meters, exactly
        // covering the camera's frustum there, and a pixel shows whatever its own place on that quad
        // says: so the eye's position decides which part of the picture a line of sight picks up.
        static Vector2 FlatScreenUv(Vector3 eye, Vector3 worldPoint, float plane)
        {
            var toCapture = Matrix4x4.TRS(k_CapturePosition, k_CaptureRotation, Vector3.one).inverse;
            var eyeInCapture = toCapture.MultiplyPoint3x4(eye);
            var pointInCapture = toCapture.MultiplyPoint3x4(worldPoint);
            var along = pointInCapture - eyeInCapture;
            var hit = eyeInCapture + along * ((plane - eyeInCapture.z) / along.z);
            return new Vector2(
                (hit.x / plane - k_Center.x) / k_Size.x + 0.5f,
                (hit.y / plane - k_Center.y) / k_Size.y + 0.5f);
        }

        [Test]
        public void NothingMapsBeforeTheFirstImageArrives()
        {
            // The quad is hidden until then, but the shader reads the same zero size and must not
            // divide by it.
            Assert.IsFalse(PassthroughController.TryImageUv(CaptureFromWorld(), Vector3.zero,
                Vector3.forward, k_Center, Vector2.zero, out _));
        }

        [Test]
        public void WhatIsBehindTheCameraIsNotDrawn()
        {
            var behind = k_CapturePosition + k_CaptureRotation * (Vector3.back * 2f);
            Assert.IsFalse(PassthroughController.TryImageUv(CaptureFromWorld(), k_CapturePosition,
                behind, k_Center, k_Size, out _));
        }

        [Test]
        public void OutsideWhatTheCameraSawIsOutsideTheImage()
        {
            // The camera sees less than a Cardboard eye, so most of the view is outside the picture:
            // the shader drops those pixels and leaves the dark border.
            var wide = k_CapturePosition + k_CaptureRotation * new Vector3(3f, 0f, 1f);
            Assert.IsTrue(PassthroughController.TryImageUv(CaptureFromWorld(), k_CapturePosition,
                wide, k_Center, k_Size, out var uv));
            Assert.IsFalse(PassthroughController.InImage(uv), $"{uv} should be outside the image");
            Assert.IsTrue(PassthroughController.InImage(Uv(k_CapturePosition,
                k_CapturePosition + k_CaptureRotation * Vector3.forward)));
        }

        static void AssertClose(Vector2 expected, Vector2 actual) =>
            Assert.That((actual - expected).magnitude, Is.LessThan(1e-5f), $"expected {expected}, got {actual}");
    }
}
