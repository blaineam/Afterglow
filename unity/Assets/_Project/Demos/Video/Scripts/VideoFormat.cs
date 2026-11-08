using System;
using System.Text.RegularExpressions;
using UnityEngine;

namespace Afterglow.Demos.Video
{
    // How much of the sphere around the viewer a video covers.
    public enum Projection
    {
        // Equirectangular, all the way around.
        Full360,
        // Equirectangular over the front half, as VR180 cameras record.
        Half180,
        // Not wrapped at all: a flat screen ahead of the viewer, as a cinema screen. What an
        // ordinary film, a 3D film and a spatial photo or video are, none of which surround you.
        Flat,
    }

    // Whether a frame holds one picture or one per eye, and how they're arranged.
    public enum StereoLayout
    {
        Mono,
        // Left eye on the left half, right eye on the right half.
        SideBySide,
        // Left eye on the top half, right eye on the bottom half.
        TopBottom,
    }

    // A video's shape: what the frame covers and whether it's 3D. Read from tags in its file name,
    // which is how 360 and VR180 files are commonly labeled, and changeable from the controls when a
    // name doesn't say.
    [Serializable]
    public struct VideoFormat : IEquatable<VideoFormat>
    {
        public Projection Projection;
        public StereoLayout Layout;

        public VideoFormat(Projection projection, StereoLayout layout)
        {
            Projection = projection;
            Layout = layout;
        }

        public static readonly VideoFormat Mono360 = new(Projection.Full360, StereoLayout.Mono);

        // Spatial photos and videos, and 3D films: one picture per eye on a screen ahead of you.
        public static readonly VideoFormat Stereo3D = new(Projection.Flat, StereoLayout.SideBySide);

        // The order the controls' Format button steps through.
        public static readonly VideoFormat[] All =
        {
            new(Projection.Full360, StereoLayout.Mono),
            new(Projection.Full360, StereoLayout.TopBottom),
            new(Projection.Half180, StereoLayout.SideBySide),
            new(Projection.Half180, StereoLayout.Mono),
            new(Projection.Full360, StereoLayout.SideBySide),
            new(Projection.Flat, StereoLayout.SideBySide),
            new(Projection.Flat, StereoLayout.TopBottom),
            new(Projection.Flat, StereoLayout.Mono),
        };

        public bool IsStereo => Layout != StereoLayout.Mono;

        // Tags are separated by anything that isn't a letter or digit: "beach_360_tb.mp4",
        // "hike-VR180.mp4", "concert 180 sbs.mov", "trailer_flat_sbs.mp4". With no tag it's mono
        // 360, the most common. A 180 video is side by side unless it says otherwise, since that's
        // what VR180 cameras make, and so is a flat one, since that's how 3D films are stored.
        public static VideoFormat FromFileName(string name)
        {
            var tokens = Regex.Split(System.IO.Path.GetFileNameWithoutExtension(name ?? "").ToLowerInvariant(), "[^a-z0-9]+");
            var half = false;
            var flat = false;
            StereoLayout? layout = null;
            foreach (var token in tokens)
            {
                switch (token)
                {
                    case "180":
                    case "vr180":
                        half = true;
                        break;
                    case "flat":
                    case "screen":
                    case "cinema":
                        flat = true;
                        break;
                    case "sbs":
                    case "lr":
                    case "3dh":
                        layout = StereoLayout.SideBySide;
                        break;
                    case "tb":
                    case "ou":
                    case "3dv":
                        layout = StereoLayout.TopBottom;
                        break;
                    case "mono":
                    case "2d":
                        layout = StereoLayout.Mono;
                        break;
                }
            }
            var projection = flat ? Projection.Flat : half ? Projection.Half180 : Projection.Full360;
            return new VideoFormat(projection,
                layout ?? (projection == Projection.Full360 ? StereoLayout.Mono : StereoLayout.SideBySide));
        }

        // The part of the frame, in texture coordinates, that an eye sees (0 left, 1 right).
        public Rect EyeRect(int eye) => Layout switch
        {
            StereoLayout.SideBySide => new Rect(eye == 0 ? 0f : 0.5f, 0f, 0.5f, 1f),
            // Texture coordinates start at the bottom, and the left eye's picture is the top one.
            StereoLayout.TopBottom => new Rect(0f, eye == 0 ? 0.5f : 0f, 1f, 0.5f),
            _ => new Rect(0f, 0f, 1f, 1f),
        };

        public VideoFormat Next()
        {
            var index = Array.IndexOf(All, this);
            return All[(index + 1) % All.Length];
        }

        public bool Equals(VideoFormat other) => Projection == other.Projection && Layout == other.Layout;

        public override bool Equals(object obj) => obj is VideoFormat other && Equals(other);

        public override int GetHashCode() => (int)Projection * 4 + (int)Layout;

        public override string ToString()
        {
            var shape = Projection switch
            {
                Projection.Full360 => "360",
                Projection.Half180 => "180",
                _ => "Screen",
            };
            return Layout switch
            {
                StereoLayout.SideBySide => $"{shape} 3D side by side",
                StereoLayout.TopBottom => $"{shape} 3D top/bottom",
                _ => $"{shape} 2D",
            };
        }
    }
}
