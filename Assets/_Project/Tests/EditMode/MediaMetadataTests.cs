using System.Collections.Generic;
using System.IO;
using System.Text;
using Afterglow.Demos.Video;
using NUnit.Framework;

namespace Afterglow.Stereo.Tests
{
    // The files are built here box by box, the way a camera or the spatial-media injector writes
    // them, so the reader is tested against the layout and not against one sample file.
    public class MediaMetadataTests
    {
        static byte[] Box(string type, params byte[][] parts)
        {
            var body = Concat(parts);
            var bytes = new byte[8 + body.Length];
            var size = (uint)bytes.Length;
            bytes[0] = (byte)(size >> 24);
            bytes[1] = (byte)(size >> 16);
            bytes[2] = (byte)(size >> 8);
            bytes[3] = (byte)size;
            Encoding.ASCII.GetBytes(type).CopyTo(bytes, 4);
            body.CopyTo(bytes, 8);
            return bytes;
        }

        static byte[] Concat(params byte[][] parts)
        {
            var all = new List<byte>();
            foreach (var part in parts)
                all.AddRange(part);
            return all.ToArray();
        }

        static byte[] Bytes(params byte[] bytes) => bytes;

        static byte[] UInt32(uint value) => new[] { (byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value };

        // A video sample entry: its 78 bytes of fields, then the children.
        static byte[] SampleEntry(params byte[][] children) => Box("avc1", Concat(new byte[78], Concat(children)));

        static byte[] Stsd(byte[] entry) => Box("stsd", UInt32(0), UInt32(1), entry);

        // A file with an ftyp, an mdat of junk and a moov holding one video track with the
        // given sample entry; mdat first, as cameras write them.
        static byte[] Mp4(byte[] sampleEntry) => Concat(
            Box("ftyp", Encoding.ASCII.GetBytes("isom"), UInt32(512)),
            Box("mdat", new byte[300]),
            Box("moov",
                Box("mvhd", new byte[100]),
                Box("trak",
                    Box("mdia",
                        Box("minf",
                            Box("stbl", Stsd(sampleEntry)))))));

        static byte[] St3d(byte mode) => Box("st3d", UInt32(0), Bytes(mode));

        static byte[] Sv3dEqui(uint left = 0, uint right = 0) => Box("sv3d",
            Box("svhd", UInt32(0), Bytes(0)),
            Box("proj",
                Box("prhd", UInt32(0), UInt32(0), UInt32(0), UInt32(0)),
                Box("equi", UInt32(0), UInt32(0), UInt32(0), UInt32(left), UInt32(right))));

        static bool Read(byte[] file, out VideoFormat format)
        {
            using var stream = new MemoryStream(file);
            return MediaMetadata.TryReadVideoFormat(stream, out format);
        }

        [Test]
        public void SphericalV2BoxesGiveTheProjectionAndTheLayout()
        {
            Assert.IsTrue(Read(Mp4(SampleEntry(St3d(1), Sv3dEqui())), out var format));
            Assert.AreEqual(new VideoFormat(Projection.Full360, StereoLayout.TopBottom), format);

            Assert.IsTrue(Read(Mp4(SampleEntry(St3d(2), Sv3dEqui())), out format));
            Assert.AreEqual(new VideoFormat(Projection.Full360, StereoLayout.SideBySide), format);

            Assert.IsTrue(Read(Mp4(SampleEntry(Sv3dEqui())), out format), "a projection alone");
            Assert.AreEqual(VideoFormat.Mono360, format);

            Assert.IsTrue(Read(Mp4(SampleEntry(St3d(2))), out format), "a layout alone is a 3D film on the screen");
            Assert.AreEqual(new VideoFormat(Projection.Flat, StereoLayout.SideBySide), format);
        }

        [Test]
        public void EquirectangularBoundsCroppedToHalfATurnAre180()
        {
            // A quarter of the full width cropped away each side.
            const uint quarter = 1u << 30;
            Assert.IsTrue(Read(Mp4(SampleEntry(St3d(2), Sv3dEqui(quarter, quarter))), out var format));
            Assert.AreEqual(new VideoFormat(Projection.Half180, StereoLayout.SideBySide), format);
        }

        [Test]
        public void AFileWithoutTheBoxesSaysNothing()
        {
            Assert.IsFalse(Read(Mp4(SampleEntry()), out _));
            Assert.IsFalse(Read(new byte[0], out _), "empty");
            Assert.IsFalse(Read(Concat(Box("ftyp", UInt32(1)), Bytes(0, 0, 0)), out _), "a truncated box");
            // A box that claims more than the file holds stops the walk rather than reading past it.
            var lying = Mp4(SampleEntry(St3d(1)));
            lying[0] = 0x7f;
            Assert.DoesNotThrow(() => Read(lying, out _));
        }

        [Test]
        public void SphericalV1XmlInAUuidBoxIsReadToo()
        {
            var uuid = new byte[]
            {
                0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd,
            };
            const string xml = "<?xml version=\"1.0\"?><rdf:SphericalVideo xmlns:GSpherical=\"http://ns.google.com/videos/1.0/spherical/\">" +
                               "<GSpherical:Spherical>true</GSpherical:Spherical><GSpherical:Stitched>true</GSpherical:Stitched>" +
                               "<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>" +
                               "<GSpherical:StereoMode>top-bottom</GSpherical:StereoMode></rdf:SphericalVideo>";
            var file = Concat(
                Box("ftyp", Encoding.ASCII.GetBytes("isom")),
                Box("moov", Box("trak", Box("uuid", uuid, Encoding.UTF8.GetBytes(xml)))),
                Box("mdat", new byte[10]));
            Assert.IsTrue(Read(file, out var format));
            Assert.AreEqual(new VideoFormat(Projection.Full360, StereoLayout.TopBottom), format);

            Assert.IsTrue(MediaMetadata.TryParseSphericalXml(
                "<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>" +
                "<GSpherical:StereoMode>left-right</GSpherical:StereoMode>" +
                "<GSpherical:FullPanoWidthPixels>7680</GSpherical:FullPanoWidthPixels>" +
                "<GSpherical:CroppedAreaImageWidthPixels>3840</GSpherical:CroppedAreaImageWidthPixels>", out format));
            Assert.AreEqual(new VideoFormat(Projection.Half180, StereoLayout.SideBySide), format, "half the width cropped is VR180");
            Assert.IsFalse(MediaMetadata.TryParseSphericalXml("<x/>", out _));
        }

        [Test]
        public void GPanoGivesTheSphereAndItsCrop()
        {
            // The attribute form, a full sphere.
            Assert.IsTrue(MediaMetadata.TryParseGPano(
                "<rdf:Description GPano:ProjectionType=\"equirectangular\" GPano:UsePanoramaViewer=\"True\"/>", out var sphere));
            Assert.AreEqual(360f, sphere.DegreesWide, 1e-3f);
            Assert.AreEqual(180f, sphere.DegreesTall, 1e-3f);
            Assert.IsTrue(sphere.IsFull);

            // The element form with a crop: half the width and a third of the height.
            Assert.IsTrue(MediaMetadata.TryParseGPano(
                "<GPano:ProjectionType>equirectangular</GPano:ProjectionType>" +
                "<GPano:FullPanoWidthPixels>6000</GPano:FullPanoWidthPixels><GPano:FullPanoHeightPixels>3000</GPano:FullPanoHeightPixels>" +
                "<GPano:CroppedAreaImageWidthPixels>3000</GPano:CroppedAreaImageWidthPixels>" +
                "<GPano:CroppedAreaImageHeightPixels>1000</GPano:CroppedAreaImageHeightPixels>", out sphere));
            Assert.AreEqual(180f, sphere.DegreesWide, 1e-3f);
            Assert.AreEqual(60f, sphere.DegreesTall, 1e-3f);
            Assert.IsFalse(sphere.IsFull);

            Assert.IsFalse(MediaMetadata.TryParseGPano("<rdf:Description GPano:ProjectionType=\"cylindrical\"/>", out _));
            Assert.IsFalse(MediaMetadata.TryParseGPano("", out _));
        }

        static byte[] Jpeg(params byte[][] segments) => Concat(Concat(Bytes(0xFF, 0xD8), Concat(segments)), Bytes(0xFF, 0xDA, 0, 2, 0xFF, 0xD9));

        static byte[] Segment(byte marker, byte[] body)
        {
            var length = body.Length + 2;
            return Concat(Bytes(0xFF, marker, (byte)(length >> 8), (byte)length), body);
        }

        static byte[] XmpSegment(string xmp) =>
            Segment(0xE1, Concat(Encoding.ASCII.GetBytes("http://ns.adobe.com/xap/1.0/"), Bytes(0), Encoding.UTF8.GetBytes(xmp)));

        [Test]
        public void TheXmpPacketIsFoundAmongAJpegsSegments()
        {
            const string xmp = "<x:xmpmeta><rdf:Description GPano:ProjectionType=\"equirectangular\"/></x:xmpmeta>";
            var exif = Segment(0xE1, Concat(Encoding.ASCII.GetBytes("Exif"), Bytes(0, 0), new byte[20]));
            var file = Jpeg(Segment(0xE0, Encoding.ASCII.GetBytes("JFIF\0")), exif, XmpSegment(xmp), Segment(0xDB, new byte[65]));
            using (var stream = new MemoryStream(file))
                Assert.AreEqual(xmp, MediaMetadata.ReadJpegXmp(stream));
            using (var stream = new MemoryStream(file))
            {
                Assert.IsTrue(MediaMetadata.TryReadPhotoSphere(stream, out var sphere));
                Assert.IsTrue(sphere.IsFull);
            }
            using (var stream = new MemoryStream(Jpeg(exif)))
                Assert.IsNull(MediaMetadata.ReadJpegXmp(stream), "no XMP");
            using (var stream = new MemoryStream(new byte[] { 0x89, 0x50, 0x4E, 0x47 }))
                Assert.IsNull(MediaMetadata.ReadJpegXmp(stream), "not a JPEG");
        }

        [Test]
        public void APhotoSphereOutranksTheFilesShape()
        {
            // 3:1 would be a 180 degree panorama by shape; GPano says it's the whole sphere.
            var full = VideoLibrary.FileImageEntry("/m/sphere.jpg", 3000, 1000, new MediaMetadata.PhotoSphere(360f, 180f));
            Assert.AreEqual(MediaKind.Still360, full.Kind);
            Assert.AreEqual(VideoFormat.Mono360, full.Format);

            // 2.5:1 would be 150 degrees by shape; GPano says 360 wide and 120 tall.
            var band = VideoLibrary.FileImageEntry("/m/wrap.jpg", 2500, 1000, new MediaMetadata.PhotoSphere(360f, 120f));
            Assert.AreEqual(MediaKind.Panorama, band.Kind);
            Assert.AreEqual(360f, VideoLibrary.PanoramaDegrees(band), 1e-3f);
            Assert.AreEqual(120f, VideoLibrary.PanoramaHeightDegrees(band), 1e-3f);
            Assert.AreEqual(360f, VideoLibrary.PanoramaDegrees(band, 1250, 500), 1e-3f, "the opened picture's size doesn't override the metadata");

            // Without GPano the shape rules as before, and the opened picture's size can refine it.
            var plain = VideoLibrary.FileImageEntry("/m/pano.jpg", 4096, 1024, null);
            Assert.AreEqual(MediaKind.Panorama, plain.Kind);
            Assert.AreEqual(240f, VideoLibrary.PanoramaDegrees(plain), 1e-3f);
            Assert.AreEqual(60f, VideoLibrary.PanoramaHeightDegrees(plain), 1e-3f);
            Assert.AreEqual(180f, VideoLibrary.PanoramaDegrees(plain, 3000, 1000), 1e-3f);
        }
    }
}
