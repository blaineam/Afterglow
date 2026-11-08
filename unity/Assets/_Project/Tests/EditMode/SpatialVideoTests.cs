using System;
using Afterglow.Demos.Video;
using NUnit.Framework;

namespace Afterglow.Stereo.Tests
{
    // Keeping a spatial video's two external textures pointed at the decoder's own memory.
    //
    // The pictures are never copied: each eye's Texture2D is a handle on a Metal texture the plugin
    // wraps around the decoder's buffer, and the plugin hands over a different one almost every
    // frame. A Texture2D can be repointed at another texture of the same shape but not at one of a
    // different shape, and repointing costs nothing while making a new Texture2D means telling
    // whatever draws it all over again -- so which of those happens is worth pinning down.
    public class SpatialVideoTextureTests
    {
        static readonly IntPtr k_First = new(0x4000);
        static readonly IntPtr k_Second = new(0x8000);
        const int k_Width = 1920;
        const int k_Height = 1080;

        [Test]
        public void NothingIsShownBeforeTheFirstFrameArrives()
        {
            Assert.AreEqual(SpatialVideo.Handover.Release,
                SpatialVideo.Next(IntPtr.Zero, 0, 0, IntPtr.Zero, 0, 0));
        }

        [Test]
        public void TheTextureGoesWhenTheVideoDoes()
        {
            // Close lets go of the decoder's buffers, so the texture that was a view of one has to
            // go with them rather than be left pointing into freed memory.
            Assert.AreEqual(SpatialVideo.Handover.Release,
                SpatialVideo.Next(k_First, k_Width, k_Height, IntPtr.Zero, 0, 0));
        }

        [Test]
        public void TheFirstFrameNeedsATextureMade()
        {
            Assert.AreEqual(SpatialVideo.Handover.Remake,
                SpatialVideo.Next(IntPtr.Zero, 0, 0, k_First, k_Width, k_Height));
        }

        [Test]
        public void TheSameFrameAgainIsLeftAlone()
        {
            // A paused video, or a frame pulled twice in one display frame: the plugin hands back
            // the texture it handed back last time.
            Assert.AreEqual(SpatialVideo.Handover.Keep,
                SpatialVideo.Next(k_First, k_Width, k_Height, k_First, k_Width, k_Height));
        }

        [Test]
        public void ANewFrameOfTheSameShapeIsOnlyRepointed()
        {
            // The ordinary case, thirty times a second: the Texture2D stays the object it was, so
            // nothing that draws it has to be told again.
            Assert.AreEqual(SpatialVideo.Handover.Repoint,
                SpatialVideo.Next(k_First, k_Width, k_Height, k_Second, k_Width, k_Height));
        }

        [Test]
        public void AChangeOfSizeNeedsANewTexture()
        {
            // An external texture carries its size, so it can't be repointed at a different one --
            // even at the same Metal texture, which is what makes this worth saying out loud.
            Assert.AreEqual(SpatialVideo.Handover.Remake,
                SpatialVideo.Next(k_First, k_Width, k_Height, k_Second, 1280, 720));
            Assert.AreEqual(SpatialVideo.Handover.Remake,
                SpatialVideo.Next(k_First, k_Width, k_Height, k_First, k_Width, 720));
        }

        [Test]
        public void AFrameWithNoSizeIsNothingToShow()
        {
            // Rather than a texture of no pixels, or a division by a zero side somewhere later.
            Assert.AreEqual(SpatialVideo.Handover.Release,
                SpatialVideo.Next(IntPtr.Zero, 0, 0, k_First, 0, k_Height));
            Assert.AreEqual(SpatialVideo.Handover.Release,
                SpatialVideo.Next(IntPtr.Zero, 0, 0, k_First, k_Width, 0));
            Assert.AreEqual(SpatialVideo.Handover.Release,
                SpatialVideo.Next(k_First, k_Width, k_Height, k_Second, -1, k_Height));
        }
    }
}
