using System.Collections.Generic;
using Afterglow.Demos.Video;
using NUnit.Framework;
using UnityEngine;

namespace Afterglow.Stereo.Tests
{
    public class MediaLibraryTests
    {
        static VideoEntry Entry(MediaKind kind, VideoFormat format = default, int library = 0) =>
            new() { Title = kind.ToString(), Kind = kind, Format = format, LibraryIndex = library };

        [TestCase(false, false, false, 4032, 3024, MediaKind.Photo)]
        [TestCase(false, false, false, 3024, 4032, MediaKind.Photo)]
        [TestCase(false, false, false, 2048, 1024, MediaKind.Still360)]
        [TestCase(false, false, false, 2000, 1024, MediaKind.Still360, TestName = "ClassifyNearly2To1IsA360Still")]
        [TestCase(false, false, false, 4096, 1024, MediaKind.Panorama)]
        [TestCase(false, false, false, 2500, 1000, MediaKind.Panorama)]
        [TestCase(false, false, true, 1000, 400, MediaKind.Panorama, TestName = "ClassifyTrustsTheLibrarysPanoramaFlag")]
        [TestCase(true, false, false, 1920, 1080, MediaKind.LibraryVideo)]
        [TestCase(false, true, false, 2048, 1536, MediaKind.SpatialPhoto)]
        [TestCase(true, true, false, 1920, 1080, MediaKind.SpatialVideo)]
        [TestCase(false, false, false, 0, 0, MediaKind.Photo, TestName = "ClassifyUnknownSizeIsAPhoto")]
        public void ClassifyReadsTheKindFromTheShape(bool video, bool spatial, bool panorama, int width, int height, MediaKind kind)
        {
            Assert.AreEqual(kind, VideoLibrary.Classify(video, spatial, panorama, width, height));
        }

        [Test]
        public void DefaultFormatsFollowTheKind()
        {
            Assert.AreEqual(VideoFormat.Mono360, VideoLibrary.DefaultFormat(MediaKind.Still360, 2048, 1024));
            Assert.AreEqual(VideoFormat.Stereo3D, VideoLibrary.DefaultFormat(MediaKind.SpatialPhoto, 2048, 1536));
            Assert.AreEqual(new VideoFormat(Projection.Flat, StereoLayout.Mono), VideoLibrary.DefaultFormat(MediaKind.Photo, 4032, 3024));
            Assert.AreEqual(new VideoFormat(Projection.Flat, StereoLayout.Mono), VideoLibrary.DefaultFormat(MediaKind.LibraryVideo, 1920, 1080));
            Assert.AreEqual(VideoFormat.Mono360, VideoLibrary.DefaultFormat(MediaKind.LibraryVideo, 2048, 1024));
        }

        [Test]
        public void PanoramaWidthFollowsItsShape()
        {
            Assert.AreEqual(240f, VideoLibrary.PanoramaDegrees(4096, 1024), 1e-3f);
            Assert.AreEqual(180f, VideoLibrary.PanoramaDegrees(3000, 1000), 1e-3f);
            Assert.AreEqual(360f, VideoLibrary.PanoramaDegrees(10000, 1000), 1e-3f, "never past a full turn");
            Assert.AreEqual(60f, VideoLibrary.PanoramaDegrees(500, 1000), 1e-3f, "never narrower than its height");
            Assert.AreEqual(180f, VideoLibrary.PanoramaDegrees(0, 0), 1e-3f, "unknown size");
        }

        [Test]
        public void FiltersPickTheirKinds()
        {
            var entries = new List<VideoEntry>
            {
                Entry(MediaKind.Photo), Entry(MediaKind.Still360, VideoFormat.Mono360), Entry(MediaKind.Panorama),
                Entry(MediaKind.LibraryVideo, new VideoFormat(Projection.Flat, StereoLayout.Mono)),
                Entry(MediaKind.LibraryVideo, VideoFormat.Mono360),
                Entry(MediaKind.SpatialPhoto, VideoFormat.Stereo3D), Entry(MediaKind.SpatialVideo, VideoFormat.Stereo3D),
                Entry(MediaKind.File, VideoFormat.Mono360, -1), Entry(MediaKind.Drive, new VideoFormat(Projection.Half180, StereoLayout.SideBySide), -1),
            };
            Assert.AreEqual(entries.Count, VideoLibrary.Filter(entries, MediaFilter.All).Count);
            CollectionAssert.AreEqual(new[] { "SpatialPhoto", "SpatialVideo" },
                VideoLibrary.Filter(entries, MediaFilter.Spatial).ConvertAll(entry => entry.Title));
            CollectionAssert.AreEqual(new[] { "Panorama" }, VideoLibrary.Filter(entries, MediaFilter.Panoramas).ConvertAll(entry => entry.Title));
            // 360 is the stills and every video that isn't a flat screen, whatever its source.
            CollectionAssert.AreEqual(new[] { "Still360", "LibraryVideo", "File", "Drive" },
                VideoLibrary.Filter(entries, MediaFilter.Still360).ConvertAll(entry => entry.Title));
            Assert.AreEqual(5, VideoLibrary.Filter(entries, MediaFilter.Videos).Count);
        }

        [Test]
        public void PicturesHaveNoClockAndLibraryItemsNoFile()
        {
            Assert.IsTrue(Entry(MediaKind.Photo).IsPicture);
            Assert.IsTrue(Entry(MediaKind.SpatialPhoto).IsPicture);
            Assert.IsFalse(Entry(MediaKind.SpatialVideo).IsPicture);
            Assert.IsTrue(Entry(MediaKind.SpatialVideo).IsVideo);
            Assert.IsTrue(Entry(MediaKind.Photo).IsLibrary);
            Assert.IsFalse(Entry(MediaKind.File, library: -1).IsLibrary);
            Assert.AreEqual(1.5f, new VideoEntry { Width = 3000, Height = 2000 }.Aspect, 1e-6f);
            Assert.AreEqual(0f, new VideoEntry().Aspect);
        }

        [Test]
        public void TheCylinderBandSpansItsAngleAndHeight()
        {
            var mesh = VideoSphere.BuildCylinderMesh(240f, 60f, 10f);
            try
            {
                var bounds = mesh.bounds;
                // 240 degrees round at radius 10: the band passes 90 degrees each side, so x reaches
                // the full radius; z runs from the back of the band (cos 120 = -5) to the front (10).
                Assert.AreEqual(10f, bounds.max.x, 0.01f);
                Assert.AreEqual(-10f, bounds.min.x, 0.01f);
                var narrow = VideoSphere.BuildCylinderMesh(120f, 60f, 10f);
                Assert.AreEqual(8.66f, narrow.bounds.max.x, 0.01f, "a 120 degree band reaches sin(60) * 10");
                Object.DestroyImmediate(narrow);
                Assert.AreEqual(10f, bounds.max.z, 0.01f);
                Assert.AreEqual(-5f, bounds.min.z, 0.01f);
                // 60 degrees tall at 10 m is 2 * 10 * tan(30) high.
                Assert.AreEqual(2f * 10f * Mathf.Tan(30f * Mathf.Deg2Rad), bounds.size.y, 0.01f);
                // Every vertex sits on the cylinder; the picture's left edge is at the band's left
                // end, 120 degrees round to the left, and its right edge at the right end.
                foreach (var vertex in mesh.vertices)
                    Assert.AreEqual(10f, new Vector2(vertex.x, vertex.z).magnitude, 1e-3f);
                var uvs = mesh.uv;
                var vertices = mesh.vertices;
                Assert.AreEqual(0f, uvs[0].x, 1e-6f);
                Assert.AreEqual(-8.66f, vertices[0].x, 0.01f);
                Assert.AreEqual(-5f, vertices[0].z, 0.01f);
                var segments = vertices.Length / 2 - 1;
                Assert.AreEqual(1f, uvs[segments].x, 1e-6f);
                Assert.AreEqual(8.66f, vertices[segments].x, 0.01f);
                Assert.AreEqual(mesh.triangles.Length / 3 * 3, mesh.triangles.Length);
            }
            finally
            {
                Object.DestroyImmediate(mesh);
            }
        }

        [Test]
        public void LibraryEntryIsNamedByWhatAndWhen()
        {
            var item = new PhotoLibrary.Item(3, "5 Nov 2026, 21:30", PhotoLibrary.Kind.Panorama, 4096, 1024, 0);
            var entry = VideoLibrary.LibraryEntry(item);
            Assert.AreEqual(MediaKind.Panorama, entry.Kind);
            Assert.AreEqual("Panorama, 5 Nov 2026, 21:30", entry.Title);
            Assert.AreEqual(3, entry.LibraryIndex);
            Assert.AreEqual(4f, entry.Aspect, 1e-6f);
            var spatial = VideoLibrary.LibraryEntry(new PhotoLibrary.Item(0, "now", PhotoLibrary.Kind.Spatial | PhotoLibrary.Kind.Video, 1920, 1080, 12.5));
            Assert.AreEqual(MediaKind.SpatialVideo, spatial.Kind);
            Assert.AreEqual(12.5, spatial.Seconds);
            Assert.AreEqual(VideoFormat.Stereo3D, spatial.Format);
        }
    }
}
