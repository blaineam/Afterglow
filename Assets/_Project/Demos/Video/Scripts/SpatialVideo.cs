using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace Afterglow.Demos.Video
{
    // Spatial video from the user's Photos library (Plugins/iOS/AfterglowSpatialVideo.mm): a
    // moving picture per eye, from the same iPhone that goes in the viewer. It opens by its place in
    // PhotoLibrary.Scan's list, which both plugins share.
    //
    // Unlike a spatial photo this has a clock, and the clock is the plugin's: AVPlayer keeps the
    // time, the audio and the looping, so playing, pausing and seeking are asked of it rather than
    // of Unity's VideoPlayer, which can only decode one of the file's two layers.
    //
    // The two pictures are the decoder's own memory, wrapped as Metal textures rather than copied,
    // so the Texture2Ds here are external: what they point at changes every frame while the objects
    // themselves usually don't. Advance does that bookkeeping and says when the objects changed,
    // which is the only time whatever draws them has to be told again.
    public static class SpatialVideo
    {
        public enum State
        {
            Idle = 0,
            Loading = 1,
            Ready = 2,
            Failed = 3,
        }

        // What showing a newly arrived frame takes, for one eye.
        public enum Handover
        {
            // Nothing to show: whatever texture there is goes.
            Release,
            // The same Metal texture as last frame, so nothing to do.
            Keep,
            // A different Metal texture of the same size: the Texture2D is pointed at the new one.
            Repoint,
            // A first frame, or one of a different size, which an external texture can't be
            // repointed to: it takes a new Texture2D.
            Remake,
        }

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        // The frame's two pictures, or null before the first one arrives. They belong to
        // SpatialVideo and are replaced as it plays, so they're worth holding no longer than the
        // frame they were asked for in.
        public static Texture2D Left { get; private set; }
        public static Texture2D Right { get; private set; }

        // Whether the file really gave two views. False means it held one and both eyes are being
        // shown the same picture, which is worth saying rather than passing off as 3D.
        public static bool Stereo { get; private set; }

        public static State PlayState =>
#if UNITY_IOS && !UNITY_EDITOR
            (State)Afterglow_SpatialVideoState();
#else
            State.Idle;
#endif

        public static string Error =>
#if UNITY_IOS && !UNITY_EDITOR
            Marshal.PtrToStringUTF8(Afterglow_SpatialVideoError()) ?? "";
#else
            "";
#endif

        // Starts loading one spatial video, which then plays on its own. False if the item isn't a
        // video this can open.
        public static bool Open(int index)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_SpatialOpenVideo(index) != 0;
#else
            return false;
#endif
        }

        public static bool Playing
        {
#if UNITY_IOS && !UNITY_EDITOR
            get => Afterglow_SpatialVideoPlaying() != 0;
            set => Afterglow_SpatialVideoSetPlaying(value ? 1 : 0);
#else
            get => false;
            set { }
#endif
        }

        public static double Time =>
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialVideoTime();
#else
            0.0;
#endif

        public static double Length =>
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialVideoLength();
#else
            0.0;
#endif

        public static void Seek(double seconds)
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialVideoSeek(seconds);
#endif
        }

        // Picks up the frame to show now. True once there is one; `changed` says the two Texture2Ds
        // are different objects from last time, which is when whatever draws them needs telling.
        public static bool Advance(out bool changed)
        {
            var left = IntPtr.Zero;
            var right = IntPtr.Zero;
            var width = 0;
            var height = 0;
#if UNITY_IOS && !UNITY_EDITOR
            // Only what a frame actually arrived with is trusted: nothing the plugin writes on the
            // way out of an empty pull is worth reading.
            if (Afterglow_SpatialVideoFrame(out left, out right, out width, out height, out var stereo) != 0)
            {
                Stereo = stereo != 0;
            }
            else
            {
                left = right = IntPtr.Zero;
                width = height = 0;
            }
#endif
            changed = Point(ref s_Left, ref s_LeftPointer, "Spatial Video Left", left, width, height);
            changed |= Point(ref s_Right, ref s_RightPointer, "Spatial Video Right", right, width, height);
            Left = s_Left;
            Right = s_Right;
            return s_Left != null && s_Right != null;
        }

        public static void Close()
        {
            // The textures go first, and only then the buffers they were views of: the other way
            // round leaves a live texture over freed memory for as long as it takes to get here,
            // and the render thread is a frame behind this one.
            Point(ref s_Left, ref s_LeftPointer, null, IntPtr.Zero, 0, 0);
            Point(ref s_Right, ref s_RightPointer, null, IntPtr.Zero, 0, 0);
            Left = s_Left;
            Right = s_Right;
            Stereo = false;
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_SpatialVideoClose();
#endif
        }

        // What to do with the texture an eye is shown through, given what it points at now and what
        // the plugin has handed over. Pure, for testing: everything about the picture holding still
        // is in here.
        public static Handover Next(IntPtr have, int haveWidth, int haveHeight,
                                    IntPtr want, int wantWidth, int wantHeight)
        {
            if (want == IntPtr.Zero || wantWidth <= 0 || wantHeight <= 0)
                return Handover.Release;
            if (have == IntPtr.Zero || haveWidth != wantWidth || haveHeight != wantHeight)
                return Handover.Remake;
            return have == want ? Handover.Keep : Handover.Repoint;
        }

        static Texture2D s_Left;
        static Texture2D s_Right;
        static IntPtr s_LeftPointer;
        static IntPtr s_RightPointer;

        // Carries out Next for one eye. True if the Texture2D itself changed.
        static bool Point(ref Texture2D texture, ref IntPtr pointer, string name,
                          IntPtr want, int width, int height)
        {
            var have = texture != null ? pointer : IntPtr.Zero;
            switch (Next(have, texture != null ? texture.width : 0, texture != null ? texture.height : 0,
                         want, width, height))
            {
                case Handover.Keep:
                    return false;

                case Handover.Repoint:
                    pointer = want;
                    texture.UpdateExternalTexture(want);
                    return false;

                case Handover.Release:
                    pointer = IntPtr.Zero;
                    if (texture == null)
                        return false;
                    UnityEngine.Object.Destroy(texture);
                    texture = null;
                    return true;

                default:
                    if (texture != null)
                        UnityEngine.Object.Destroy(texture);
                    // BGRA and not linear, matching the sRGB Metal texture the plugin wraps the
                    // decoder's buffer in, so the GPU converts as it samples.
                    texture = Texture2D.CreateExternalTexture(width, height, TextureFormat.BGRA32, false, false, want);
                    texture.name = name;
                    texture.wrapMode = TextureWrapMode.Clamp;
                    pointer = want;
                    return true;
            }
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_SpatialOpenVideo(int index);
        [DllImport("__Internal")] static extern int Afterglow_SpatialVideoState();
        [DllImport("__Internal")] static extern IntPtr Afterglow_SpatialVideoError();
        [DllImport("__Internal")] static extern int Afterglow_SpatialVideoFrame(out IntPtr left, out IntPtr right, out int width, out int height, out int stereo);
        [DllImport("__Internal")] static extern void Afterglow_SpatialVideoSetPlaying(int playing);
        [DllImport("__Internal")] static extern int Afterglow_SpatialVideoPlaying();
        [DllImport("__Internal")] static extern double Afterglow_SpatialVideoTime();
        [DllImport("__Internal")] static extern double Afterglow_SpatialVideoLength();
        [DllImport("__Internal")] static extern void Afterglow_SpatialVideoSeek(double seconds);
        [DllImport("__Internal")] static extern void Afterglow_SpatialVideoClose();
#endif
    }
}
