using Afterglow.Hands;
using NUnit.Framework;
using Unity.Collections;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    public class HandDumpTests
    {
        [Test]
        public void AModelInputComesOutUprightWithItsColours()
        {
            // A 2x2 input whose first row (the top) is red then green, second row blue then white.
            var rgb = new float[] { 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1 };
            var texture = HandDump.FromInput(rgb, 2);
            try
            {
                Assert.AreEqual(Color.red, texture.GetPixel(0, 1), "top left is red, at Unity's top row");
                Assert.AreEqual(Color.green, texture.GetPixel(1, 1));
                Assert.AreEqual(Color.blue, texture.GetPixel(0, 0), "bottom left is blue");
                Assert.AreEqual(Color.white, texture.GetPixel(1, 0));
            }
            finally
            {
                Object.DestroyImmediate(texture);
            }
        }

        [Test]
        public void TheCameraImageIsShrunkAndKeptUpright()
        {
            // 4x2 RGBA, first row the top: the top-left pixel red, the bottom-left blue.
            var rgba = new NativeArray<byte>(4 * 2 * 4, Allocator.Temp);
            try
            {
                rgba[0] = 255; rgba[3] = 255;
                rgba[4 * 4 + 2] = 255; rgba[4 * 4 + 3] = 255;
                var texture = HandDump.FromImage(rgba, 4, 2, 2);
                try
                {
                    Assert.AreEqual(2, texture.width);
                    Assert.AreEqual(1, texture.height);
                    Assert.AreEqual(Color.red, texture.GetPixel(0, 0), "every other pixel from the top row");
                }
                finally
                {
                    Object.DestroyImmediate(texture);
                }
            }
            finally
            {
                rgba.Dispose();
            }
        }
    }
}
