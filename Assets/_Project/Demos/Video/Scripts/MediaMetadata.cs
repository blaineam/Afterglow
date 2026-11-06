using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using UnityEngine;

namespace Afterglow.Demos.Video
{
    // What a media file says about its own shape, read from its metadata rather than guessed
    // from its name or its proportions:
    //   - a video's spherical-video boxes: v2's `st3d` (the stereo layout) and `sv3d`/`proj`/`equi`
    //     (equirectangular, with the bounds that make a 180° video), inside the sample entry;
    //     and v1's `uuid` box with the GSpherical XML, which older 360 cameras wrote;
    //   - a JPEG's GPano XMP (Google's photo sphere), which says the picture is equirectangular
    //     and how much of the sphere it covers, so a panorama's span and height come from the
    //     camera that swept it rather than from a 60° guess.
    // Pure: streams in, answers out; nothing here touches Unity but the log. A file without the
    // metadata is simply "nothing found", never an error, and a damaged file is read as far as it
    // goes. The Photos library's own items are classified by the library's subtypes; this is for
    // files in the Media folder.
    public static class MediaMetadata
    {
        // How much of the sphere a photo sphere covers, centred ahead.
        public readonly struct PhotoSphere
        {
            public readonly float DegreesWide;
            public readonly float DegreesTall;

            public PhotoSphere(float degreesWide, float degreesTall)
            {
                DegreesWide = degreesWide;
                DegreesTall = degreesTall;
            }

            // The whole sphere, or near enough to wrap on the sphere rather than a band.
            public bool IsFull => DegreesWide >= 359f && DegreesTall >= 170f;
        }

        // Boxes that are read into for the ones that matter; everything else is skipped by size.
        static readonly HashSet<string> k_Containers = new() { "moov", "trak", "mdia", "minf", "stbl", "sv3d", "proj" };
        // Spherical video v1's uuid, from the spec: ffcc8263-f855-4a93-8814-587a02521fdd.
        static readonly byte[] k_SphericalUuid =
        {
            0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd,
        };
        const int k_MaxDepth = 12;
        // A box bigger than this is skipped unread even when it's one that is normally read, so a
        // broken size can't ask for gigabytes.
        const long k_MaxReadBox = 4 << 20;

        // The format a video file's boxes describe: true with it when the file has `st3d`, `sv3d`
        // or the v1 XML. A stereo layout without a projection is a flat 3D film; a projection
        // without a layout is mono.
        public static bool TryReadVideoFormat(string path, out VideoFormat format)
        {
            format = default;
            try
            {
                using var stream = File.OpenRead(path);
                return TryReadVideoFormat(stream, out format);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                Debug.LogWarning($"[Video] Couldn't read {Path.GetFileName(path)} for its format: {e.Message}");
                return false;
            }
        }

        public static bool TryReadVideoFormat(Stream stream, out VideoFormat format)
        {
            var found = new Found();
            WalkBoxes(stream, 0, stream.Length, 0, found);
            return found.ToFormat(out format);
        }

        // What was found while walking, from whichever version of the metadata was there.
        class Found
        {
            public StereoLayout? Layout;
            public Projection? Projection;

            public bool ToFormat(out VideoFormat format)
            {
                format = default;
                if (Layout == null && Projection == null)
                    return false;
                format = new VideoFormat(Projection ?? Video.Projection.Flat, Layout ?? StereoLayout.Mono);
                return true;
            }
        }

        static void WalkBoxes(Stream stream, long start, long end, int depth, Found found)
        {
            if (depth > k_MaxDepth)
                return;
            var header = new byte[16];
            var position = start;
            while (position + 8 <= end)
            {
                stream.Position = position;
                if (!ReadExactly(stream, header, 8))
                    return;
                long size = ReadUInt32(header, 0);
                var type = Encoding.ASCII.GetString(header, 4, 4);
                var headerSize = 8;
                if (size == 1)
                {
                    if (!ReadExactly(stream, header, 8))
                        return;
                    size = (long)ReadUInt64(header, 0);
                    headerSize = 16;
                }
                else if (size == 0)
                {
                    size = end - position;
                }
                if (size < headerSize || position + size > end)
                    return;
                var bodyStart = position + headerSize;
                var bodyEnd = position + size;
                switch (type)
                {
                    case "stsd":
                        // A full box with an entry count, then the sample entries.
                        WalkSampleEntries(stream, bodyStart + 8, bodyEnd, depth + 1, found);
                        break;
                    case "st3d":
                        ReadStereo(stream, bodyStart, bodyEnd, found);
                        break;
                    case "equi":
                        ReadEquirectangular(stream, bodyStart, bodyEnd, found);
                        break;
                    case "cbmp":
                    case "mshp":
                        // Cubemaps and meshes aren't drawn here; the file is still a wrapped one,
                        // and 360 is the nearest the player has.
                        found.Projection ??= Projection.Full360;
                        break;
                    case "uuid":
                        ReadSphericalV1(stream, bodyStart, bodyEnd, found);
                        break;
                    default:
                        if (k_Containers.Contains(type))
                            WalkBoxes(stream, bodyStart, bodyEnd, depth + 1, found);
                        break;
                }
                position = bodyEnd;
            }
        }

        // The sample entries in an stsd: each a box whose visual fields take 78 bytes before any
        // child box (st3d and sv3d among them). A sound track's entries are walked the same way
        // and simply hold nothing of interest.
        static void WalkSampleEntries(Stream stream, long start, long end, int depth, Found found)
        {
            var header = new byte[8];
            var position = start;
            while (position + 8 <= end)
            {
                stream.Position = position;
                if (!ReadExactly(stream, header, 8))
                    return;
                long size = ReadUInt32(header, 0);
                if (size < 8 || position + size > end)
                    return;
                const int visualFields = 78;
                if (size > 8 + visualFields)
                    WalkBoxes(stream, position + 8 + visualFields, position + size, depth + 1, found);
                position += size;
            }
        }

        static void ReadStereo(Stream stream, long start, long end, Found found)
        {
            // version(1) flags(3) stereo_mode(1)
            if (end - start < 5)
                return;
            var bytes = new byte[5];
            stream.Position = start;
            if (!ReadExactly(stream, bytes, 5))
                return;
            found.Layout = bytes[4] switch
            {
                1 => StereoLayout.TopBottom,
                2 => StereoLayout.SideBySide,
                _ => StereoLayout.Mono,
            };
        }

        static void ReadEquirectangular(Stream stream, long start, long end, Found found)
        {
            // version(1) flags(3) then four 0.32 fixed-point bounds: top, bottom, left, right —
            // how much of the full sphere is cropped away on each side. Half a turn cropped
            // between left and right is a 180° video.
            found.Projection = Projection.Full360;
            if (end - start < 20)
                return;
            var bytes = new byte[20];
            stream.Position = start;
            if (!ReadExactly(stream, bytes, 20))
                return;
            var left = ReadUInt32(bytes, 12) / 4294967296.0;
            var right = ReadUInt32(bytes, 16) / 4294967296.0;
            if (left + right >= 0.45)
                found.Projection = Projection.Half180;
        }

        static void ReadSphericalV1(Stream stream, long start, long end, Found found)
        {
            if (end - start < 16 || end - start > k_MaxReadBox)
                return;
            var bytes = new byte[end - start];
            stream.Position = start;
            if (!ReadExactly(stream, bytes, bytes.Length))
                return;
            for (var i = 0; i < 16; i++)
            {
                if (bytes[i] != k_SphericalUuid[i])
                    return;
            }
            ParseSphericalXml(Encoding.UTF8.GetString(bytes, 16, bytes.Length - 16), found);
        }

        // The v1 XML: GSpherical:Spherical, ProjectionType, StereoMode, and the crop that a 180
        // video declares. Pure, for testing.
        public static bool TryParseSphericalXml(string xml, out VideoFormat format)
        {
            var found = new Found();
            ParseSphericalXml(xml, found);
            return found.ToFormat(out format);
        }

        static void ParseSphericalXml(string xml, Found found)
        {
            if (string.IsNullOrEmpty(xml))
                return;
            var projection = Element(xml, "GSpherical:ProjectionType");
            if (projection != null && projection.Trim().Equals("equirectangular", StringComparison.OrdinalIgnoreCase))
            {
                found.Projection = Projection.Full360;
                if (Number(xml, "GSpherical:FullPanoWidthPixels", out var full) &&
                    Number(xml, "GSpherical:CroppedAreaImageWidthPixels", out var cropped) && full > 0 &&
                    cropped / full <= 0.55)
                    found.Projection = Projection.Half180;
            }
            var stereo = Element(xml, "GSpherical:StereoMode");
            if (stereo != null)
            {
                found.Layout = stereo.Trim().ToLowerInvariant() switch
                {
                    "top-bottom" => StereoLayout.TopBottom,
                    "left-right" => StereoLayout.SideBySide,
                    _ => StereoLayout.Mono,
                };
            }
        }

        // A JPEG's photo sphere, from the GPano XMP in its APP1 segment: true with how much of
        // the sphere it covers.
        public static bool TryReadPhotoSphere(string path, out PhotoSphere sphere)
        {
            sphere = default;
            try
            {
                using var stream = File.OpenRead(path);
                return TryReadPhotoSphere(stream, out sphere);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                Debug.LogWarning($"[Video] Couldn't read {Path.GetFileName(path)} for GPano: {e.Message}");
                return false;
            }
        }

        public static bool TryReadPhotoSphere(Stream stream, out PhotoSphere sphere)
        {
            sphere = default;
            var xmp = ReadJpegXmp(stream);
            return xmp != null && TryParseGPano(xmp, out sphere);
        }

        const string k_XmpHeader = "http://ns.adobe.com/xap/1.0/";

        // The XMP packet in a JPEG's APP1 segments, up to the first scan; null without one.
        public static string ReadJpegXmp(Stream stream)
        {
            var header = new byte[4];
            stream.Position = 0;
            if (!ReadExactly(stream, header, 2) || header[0] != 0xFF || header[1] != 0xD8)
                return null;
            while (ReadExactly(stream, header, 4))
            {
                if (header[0] != 0xFF)
                    return null;
                var marker = header[1];
                // Padding bytes between segments.
                if (marker == 0xFF)
                {
                    stream.Position -= 3;
                    continue;
                }
                // The scan: no more headers after it.
                if (marker == 0xDA || marker == 0xD9)
                    return null;
                var length = (header[2] << 8 | header[3]) - 2;
                if (length < 0)
                    return null;
                if (marker == 0xE1 && length > k_XmpHeader.Length + 1 && length <= k_MaxReadBox)
                {
                    var body = new byte[length];
                    if (!ReadExactly(stream, body, length))
                        return null;
                    if (Encoding.ASCII.GetString(body, 0, k_XmpHeader.Length) == k_XmpHeader && body[k_XmpHeader.Length] == 0)
                        return Encoding.UTF8.GetString(body, k_XmpHeader.Length + 1, length - k_XmpHeader.Length - 1);
                    continue;
                }
                stream.Position += length;
            }
            return null;
        }

        // GPano as attributes (GPano:ProjectionType="equirectangular") or elements
        // (<GPano:ProjectionType>equirectangular</GPano:ProjectionType>), either way the schema
        // writes them. Without the crop numbers the picture is the whole sphere. Pure, for testing.
        public static bool TryParseGPano(string xmp, out PhotoSphere sphere)
        {
            sphere = default;
            if (string.IsNullOrEmpty(xmp))
                return false;
            var projection = Element(xmp, "GPano:ProjectionType");
            if (projection == null || !projection.Trim().Equals("equirectangular", StringComparison.OrdinalIgnoreCase))
                return false;
            var wide = 360f;
            var tall = 180f;
            if (Number(xmp, "GPano:FullPanoWidthPixels", out var fullWidth) &&
                Number(xmp, "GPano:CroppedAreaImageWidthPixels", out var croppedWidth) && fullWidth > 0 && croppedWidth > 0)
                wide = Mathf.Clamp((float)(croppedWidth / fullWidth * 360.0), 1f, 360f);
            if (Number(xmp, "GPano:FullPanoHeightPixels", out var fullHeight) &&
                Number(xmp, "GPano:CroppedAreaImageHeightPixels", out var croppedHeight) && fullHeight > 0 && croppedHeight > 0)
                tall = Mathf.Clamp((float)(croppedHeight / fullHeight * 180.0), 1f, 180f);
            sphere = new PhotoSphere(wide, tall);
            return true;
        }

        // An XML value written either way: name="value" or <name>value</name>.
        static string Element(string xml, string name)
        {
            var attribute = Regex.Match(xml, Regex.Escape(name) + "\\s*=\\s*\"([^\"]*)\"");
            if (attribute.Success)
                return attribute.Groups[1].Value;
            var element = Regex.Match(xml, "<" + Regex.Escape(name) + "(?:\\s[^>]*)?>([^<]*)</" + Regex.Escape(name) + ">");
            return element.Success ? element.Groups[1].Value : null;
        }

        static bool Number(string xml, string name, out double value)
        {
            value = 0;
            var text = Element(xml, name);
            return text != null && double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
        }

        static bool ReadExactly(Stream stream, byte[] buffer, int count)
        {
            var got = 0;
            while (got < count)
            {
                var read = stream.Read(buffer, got, count - got);
                if (read <= 0)
                    return false;
                got += read;
            }
            return true;
        }

        static uint ReadUInt32(byte[] bytes, int offset) =>
            (uint)bytes[offset] << 24 | (uint)bytes[offset + 1] << 16 | (uint)bytes[offset + 2] << 8 | bytes[offset + 3];

        static ulong ReadUInt64(byte[] bytes, int offset) => (ulong)ReadUInt32(bytes, offset) << 32 | ReadUInt32(bytes, offset + 4);
    }
}
