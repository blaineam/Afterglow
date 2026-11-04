using System.Collections;
using System.Collections.Generic;
using TMPro;
using CardboardXR.UI;
using UnityEngine;
using UnityEngine.Video;

namespace CardboardXR.Demos.Video
{
    // Watch 360 and VR180 videos, 2D or 3D, and the spatial photos and videos the phone itself
    // took. It opens on a library of what's on the phone (see VideoLibrary); pick one and it plays
    // around you, or, for a spatial one, on a screen ahead of you with a picture per eye. Pinch (or tap the screen) anywhere on the
    // video to bring up the controls, a little below where you're looking: play and pause, jump back
    // or ahead 10 s, seek by clicking the bar, the next video, the format (when a file's name doesn't
    // say it), and the library (the lobby is on the settings panel). Pinch on the video again to
    // put them away. They stay where they appeared rather than following the head, so they can be
    // looked at.
    // The demo runs in 3DoF with the AR session and hand tracking off; PinchInput's light pinch
    // detector runs, slowing down with no hand in view, leaving most of the heat to the video
    // decoder. Logs [Video].
    [RequireComponent(typeof(VideoPlayer))]
    public class VideoDemo : Demo
    {
        // The controls appear this far below where the head looks, in degrees, so they don't cover
        // what was being watched, but no lower than k_LowestPitch.
        const float k_ControlsBelowGaze = 20f;
        const float k_LowestPitch = -60f;
        const float k_PanelDistance = 1.5f;
        const float k_SkipSeconds = 10f;
        const int k_EntriesPerPage = 5;
        const float k_StatusSeconds = 5f;

        [SerializeField] VideoSphere m_Sphere;
        // The repository's placeholders. Any other videos in StreamingAssets (Tools/make_videos.sh copies
        // your own in for local builds) come first.
        [Tooltip("Videos in StreamingAssets, offered first, so there's something to watch without copying any.")]
        [SerializeField] string[] m_Bundled = { "Sample_360.mp4", "Sample_180_sbs.mp4" };

        CoreServices m_Core;
        VideoPlayer m_Player;
        RenderTexture m_Texture;
        List<VideoEntry> m_Library = new();
        int m_Current = -1;
        int m_Wanted = -1;
        Coroutine m_Download;
        int m_Dropped;
        float m_NextStatus;
        Texture2D m_SpatialLeft;
        Texture2D m_SpatialRight;
        bool m_WaitingForSpatial;
        // A spatial video the plugin has open, and whether its first frame has reached the screen.
        bool m_SpatialVideoOpen;
        bool m_SpatialVideoShown;
        // Whether the Photos library question has been settled, either way, so it is asked once.
        bool m_SpatialSettled;

        RectTransform m_Panel;
        RectTransform m_LibraryPage;
        RectTransform m_ControlsPage;
        TMP_Text m_Title;
        TMP_Text m_FormatLine;
        TMP_Text m_Time;
        M3Button m_Play;
        M3Slider m_Seek;
        TMP_Text m_PageLabel;
        M3Button m_PreviousPage;
        M3Button m_NextPage;
        TMP_Text m_EmptyMessage;
        readonly List<(M3Button item, TMP_Text supporting)> m_EntryButtons = new();
        int m_Page;
        bool m_ShowingLibrary;
        bool m_ControlsShown;

        public override void OnDemoEnter(CoreServices core)
        {
            m_Core = core;
            m_Player = GetComponent<VideoPlayer>();
            m_Player.playOnAwake = false;
            m_Player.source = VideoSource.Url;
            m_Player.renderMode = VideoRenderMode.RenderTexture;
            m_Player.isLooping = true;
            m_Player.skipOnDrop = true;
            m_Player.audioOutputMode = VideoAudioOutputMode.Direct;
            m_Player.prepareCompleted += OnPrepared;
            m_Player.errorReceived += OnError;
            m_Player.frameDropped += OnFrameDropped;
            m_Sphere.Clicked += OnVideoClicked;

            BuildPanel();
            // Put iOS's Photos question up as the demo opens rather than when a photo is picked, so
            // the library can list the user's spatial photos alongside the files straight away.
            m_SpatialSettled = !SpatialPhotos.Supported ||
                               SpatialPhotos.Authorize() != SpatialPhotos.Access.Asking;
            Refresh();
            ShowLibrary();
        }

        public override void OnDemoExit(CoreServices core)
        {
            if (m_Download != null)
                StopCoroutine(m_Download);
            m_Player.prepareCompleted -= OnPrepared;
            m_Player.errorReceived -= OnError;
            m_Player.frameDropped -= OnFrameDropped;
            m_Sphere.Clicked -= OnVideoClicked;
            m_Player.Stop();
            m_Sphere.Show(null, default);
            ReleaseTexture();
            ReleaseSpatial();
        }

        void OnDestroy()
        {
            ReleaseTexture();
            ReleaseSpatial();
        }

        void Update()
        {
            if (m_Core == null)
                return;
            if (m_WaitingForSpatial)
                UpdateSpatialPhoto();
            if (m_SpatialVideoOpen)
                UpdateSpatialVideo();
            // The Photos question is answered after the demo has opened, so once it is, the library
            // is listed again with the spatial photos in it.
            if (!m_SpatialSettled && SpatialPhotos.Authorize() != SpatialPhotos.Access.Asking)
            {
                m_SpatialSettled = true;
                Refresh();
                if (m_ShowingLibrary)
                    ShowLibrary();
            }

            if (m_ShowingLibrary)
                UpdateLibraryLabels();
            else if (m_ControlsShown)
                UpdateControls();

            if (Current != null && PlaybackReady && Time.unscaledTime >= m_NextStatus)
            {
                m_NextStatus = Time.unscaledTime + k_StatusSeconds;
                var where = $"at {Clock(PlaybackTime)} of {Clock(PlaybackLength)}";
                // A spatial video's frames come from the plugin, so VideoPlayer's dropped count
                // says nothing about it; whether both eyes arrived is what's worth watching there.
                Debug.Log(OnSpatialVideo
                    ? $"[Video] Spatial video {(PlaybackPlaying ? "playing" : "paused")} {where}, " +
                      $"{(SpatialVideo.Stereo ? "both eyes" : "one eye shown to both")}"
                    : $"[Video] {(PlaybackPlaying ? "Playing" : "Paused")} {where}, " +
                      $"{m_Dropped} frames dropped in the last {k_StatusSeconds:F0} s");
                m_Dropped = 0;
            }
        }

        void Refresh()
        {
            // The list is built from scratch, so whatever is playing is found again in the new one
            // rather than left at the index it used to be at: a file copied in or deleted meanwhile
            // shifts everything after it, and the controls would go on describing someone else.
            var playing = Current;
            m_Library = VideoLibrary.Find(m_Bundled, out var bundled);
            m_Current = playing == null ? -1 : m_Library.FindIndex(entry => Same(entry, playing));
            m_Page = 0;
            Debug.Log($"[Video] {m_Library.Count} videos: {bundled} bundled, the rest from {VideoLibrary.VideoFolder}");
        }

        // What's playing, or null. The library can be rebuilt underneath it (Refresh, and the
        // Photos question being answered after the demo has opened), so the index is never trusted
        // to still be in range.
        VideoEntry Current => m_Current >= 0 && m_Current < m_Library.Count ? m_Library[m_Current] : null;

        // Whether two entries from different scans of the library are the same item. Nothing is
        // shared across the three kinds, so one kind is never the same as another.
        //   A spatial photo or video goes by its title, which is its creation date: its index is a
        // place in a scan of the Photos library, and a scan that picks up a newly taken photo
        // shifts every index after it. A Drive video goes by its file id, which is what it is, and
        // a file by its path.
        public static bool Same(VideoEntry a, VideoEntry b)
        {
            if (a == null || b == null)
                return false;
            if (a.IsSpatial || b.IsSpatial)
                return a.IsSpatial == b.IsSpatial && a.SpatialIsVideo == b.SpatialIsVideo && a.Title == b.Title;
            if (a.DriveId != null || b.DriveId != null)
                return a.DriveId == b.DriveId;
            return a.Url != null && a.Url == b.Url;
        }

        // Plays an entry, downloading it first if it's a Drive video not yet in the cache.
        void Play(int index)
        {
            if (index < 0 || index >= m_Library.Count)
                return;
            var entry = m_Library[index];
            m_Wanted = index;
            if (entry.NeedsDownload)
            {
                if (m_Download == null)
                    m_Download = StartCoroutine(DownloadThenPlay(entry, index));
                return;
            }

            if (entry.IsSpatialPhoto)
            {
                PlaySpatialPhoto(entry, index);
                return;
            }
            if (entry.IsSpatialVideo)
            {
                PlaySpatialVideo(entry, index);
                return;
            }

            m_Player.Stop();
            // Off the screen before the pictures go: a spatial video's textures are views of the
            // decoder's own memory, and one left on the quad would be drawn from freed buffers.
            m_Sphere.Show(null, default);
            ReleaseSpatial();
            m_Current = index;
            m_Player.url = entry.Url;
            m_Player.Prepare();
            m_Title.text = entry.Title;
            entry.Status = "Loading";
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Format})");
        }

        // A spatial photo is two pictures rather than a stream, so it doesn't go through
        // VideoPlayer at all: the plugin decodes both of the file's eyes and Update picks them up
        // when they're ready.
        void PlaySpatialPhoto(VideoEntry entry, int index)
        {
            m_Player.Stop();
            // Off the screen before the pictures go: a spatial video's textures are views of the
            // decoder's own memory, and one left on the quad would be drawn from freed buffers.
            m_Sphere.Show(null, default);
            ReleaseSpatial();
            m_Current = index;
            m_Title.text = entry.Title;

            if (SpatialPhotos.Authorize() != SpatialPhotos.Access.Granted)
            {
                entry.Status = "Allow Photos to show this";
                Debug.Log("[Video] The Photos library isn't allowed yet, so the spatial photo stays shut");
                return;
            }
            if (!SpatialPhotos.OpenPhoto(entry.SpatialIndex))
            {
                m_Current = -1;
                entry.Status = "Couldn't open that spatial photo";
                Debug.LogWarning($"[Video] Couldn't open {entry.Title}");
                ShowLibrary();
                return;
            }
            entry.Status = "Loading";
            m_WaitingForSpatial = true;
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Format})");
        }

        // Polled while a spatial photo loads, since the plugin decodes it off the main thread.
        void UpdateSpatialPhoto()
        {
            switch (SpatialPhotos.PhotoState)
            {
                case SpatialPhotos.State.Loading:
                    return;
                case SpatialPhotos.State.Ready:
                    m_WaitingForSpatial = false;
                    if (!SpatialPhotos.TryTakeTextures(out m_SpatialLeft, out m_SpatialRight))
                    {
                        FailSpatial("That spatial photo's pictures couldn't be uploaded");
                        return;
                    }
                    // A picture each, so the format's halves aren't used: the eyes are whole.
                    m_Sphere.Show(m_SpatialLeft, VideoFormat.Stereo3D, m_SpatialRight);
                    if (Current != null)
                        Current.Status = null;
                    Debug.Log($"[Video] Spatial photo shown: {m_SpatialLeft.width}x{m_SpatialLeft.height} per eye");
                    HidePanel();
                    // The pictures are in textures now, so the plugin needn't keep its buffers.
                    SpatialPhotos.Close();
                    return;
                default:
                    FailSpatial(SpatialPhotos.PhotoError);
                    return;
            }
        }

        // A spatial video doesn't go through VideoPlayer either, and for a different reason: it
        // would decode one of the file's two layers and play the result flat. The plugin decodes
        // both and keeps the clock and the audio, so the controls ask it rather than VideoPlayer
        // (see OnSpatialVideo), and Update picks up each frame's two pictures.
        void PlaySpatialVideo(VideoEntry entry, int index)
        {
            m_Player.Stop();
            // Off the screen before the pictures go: a spatial video's textures are views of the
            // decoder's own memory, and one left on the quad would be drawn from freed buffers.
            m_Sphere.Show(null, default);
            ReleaseSpatial();
            m_Current = index;
            m_Title.text = entry.Title;

            if (SpatialPhotos.Authorize() != SpatialPhotos.Access.Granted)
            {
                entry.Status = "Allow Photos to show this";
                Debug.Log("[Video] The Photos library isn't allowed yet, so the spatial video stays shut");
                return;
            }
            if (!SpatialVideo.Open(entry.SpatialIndex))
            {
                var why = SpatialVideo.Error;
                m_Current = -1;
                entry.Status = string.IsNullOrEmpty(why) ? "Couldn't open that spatial video" : why;
                Debug.LogWarning($"[Video] Couldn't open {entry.Title}: {entry.Status}");
                ShowLibrary();
                return;
            }
            entry.Status = "Loading";
            m_SpatialVideoOpen = true;
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Format})");
        }

        // Polled while a spatial video is open. The library fetch runs off the main thread, and
        // after it every frame has two new pictures: Advance takes them and says when the textures
        // themselves changed, which is the only time the screen has to be told again.
        void UpdateSpatialVideo()
        {
            switch (SpatialVideo.PlayState)
            {
                case SpatialVideo.State.Loading:
                    return;
                case SpatialVideo.State.Ready:
                    if (!SpatialVideo.Advance(out var changed) || !changed)
                        return;
                    m_Sphere.Show(SpatialVideo.Left, VideoFormat.Stereo3D, SpatialVideo.Right);
                    if (m_SpatialVideoShown)
                        return;
                    m_SpatialVideoShown = true;
                    if (Current != null)
                        Current.Status =
                            SpatialVideo.Stereo ? null : "One eye only: that file holds a single view";
                    Debug.Log($"[Video] Spatial video playing: {SpatialVideo.Left.width}x{SpatialVideo.Left.height} per eye, " +
                              $"{(SpatialVideo.Stereo ? "both eyes" : "one eye shown to both")}, {Clock(PlaybackLength)}");
                    HidePanel();
                    return;
                default:
                    FailSpatial(SpatialVideo.Error);
                    return;
            }
        }

        void FailSpatial(string message)
        {
            var kind = Current != null && Current.IsSpatialVideo ? "video" : "photo";
            if (Current != null)
                Current.Status = string.IsNullOrEmpty(message) ? $"Couldn't show that spatial {kind}" : message;
            Debug.LogWarning($"[Video] Spatial {kind} failed: {(string.IsNullOrEmpty(message) ? "no reason given" : message)}");
            m_Current = -1;
            m_Sphere.Show(null, default);
            ReleaseSpatial();
            ShowLibrary();
        }

        void ReleaseSpatial()
        {
            m_WaitingForSpatial = false;
            m_SpatialVideoOpen = false;
            m_SpatialVideoShown = false;
            SpatialPhotos.Close();
            // Closing lets go of the decoder's buffers, and with them the textures that were views
            // of them, so nothing is left pointing into freed memory.
            SpatialVideo.Close();
            if (m_SpatialLeft != null)
                Destroy(m_SpatialLeft);
            if (m_SpatialRight != null)
                Destroy(m_SpatialRight);
            m_SpatialLeft = m_SpatialRight = null;
        }

        // Whatever is playing, asked through one set of questions rather than a branch at every
        // button. A file goes through Unity's VideoPlayer and a spatial video through the plugin;
        // a spatial photo has no clock at all, and VideoPlayer, stopped, answers for it as a still.
        bool OnSpatialVideo => Current is { IsSpatialVideo: true };

        bool PlaybackReady => OnSpatialVideo
            ? SpatialVideo.PlayState == SpatialVideo.State.Ready && m_SpatialVideoShown
            : m_Player.isPrepared;

        bool PlaybackPlaying => OnSpatialVideo ? SpatialVideo.Playing : m_Player.isPlaying;

        bool PlaybackCanSeek => OnSpatialVideo || m_Player.canSetTime;

        double PlaybackTime => OnSpatialVideo ? SpatialVideo.Time : m_Player.time;

        double PlaybackLength => OnSpatialVideo ? SpatialVideo.Length : m_Player.length;

        void PlaybackSetPlaying(bool playing)
        {
            if (OnSpatialVideo)
                SpatialVideo.Playing = playing;
            else if (playing)
                m_Player.Play();
            else
                m_Player.Pause();
        }

        IEnumerator DownloadThenPlay(VideoEntry entry, int index)
        {
            yield return DriveDownloader.Download(entry, null);
            m_Download = null;
            // Only if it's still the one wanted: something else may have been picked meanwhile.
            if (entry.Url != null && m_Wanted == index)
                Play(index);
        }

        void OnPrepared(VideoPlayer player)
        {
            var entry = Current;
            // The library was rebuilt while this was opening and what was asked for has gone.
            if (entry == null)
            {
                player.Stop();
                return;
            }
            var width = (int)player.width;
            var height = (int)player.height;
            if (m_Texture == null || m_Texture.width != width || m_Texture.height != height)
            {
                ReleaseTexture();
                m_Texture = new RenderTexture(width, height, 0) { name = "Video" };
            }
            player.targetTexture = m_Texture;
            m_Sphere.Show(m_Texture, entry.Format);
            player.Play();
            entry.Status = null;
            m_Dropped = 0;
            m_NextStatus = Time.unscaledTime + k_StatusSeconds;
            Debug.Log($"[Video] Playing {entry.Title}: {width}x{height} at {player.frameRate:F0} fps, {Clock(player.length)}, " +
                      $"{entry.Format}, {player.audioTrackCount} audio tracks");
            HidePanel();
        }

        void OnError(VideoPlayer player, string message)
        {
            var entry = Current;
            if (entry != null)
                entry.Status = $"Couldn't play: {message}";
            Debug.LogWarning($"[Video] Couldn't play {entry?.Title ?? player.url}: {message}");
            m_Current = -1;
            m_Sphere.Show(null, default);
            ShowLibrary();
        }

        void OnFrameDropped(VideoPlayer player) => m_Dropped++;

        void TogglePlay()
        {
            if (m_Current < 0 || !PlaybackReady)
                return;
            PlaybackSetPlaying(!PlaybackPlaying);
            Debug.Log($"[Video] {(PlaybackPlaying ? "Resumed" : "Paused")} at {Clock(PlaybackTime)}");
        }

        void Skip(float seconds) => SeekTo(PlaybackTime + seconds);

        void SeekTo(double seconds)
        {
            if (m_Current < 0 || !PlaybackReady || !PlaybackCanSeek)
                return;
            // The player moves there a moment later, so log the target: reading its time back here
            // still gives where it was.
            var target = System.Math.Clamp(seconds, 0.0, System.Math.Max(0.0, PlaybackLength - 0.5));
            Debug.Log($"[Video] Seek from {Clock(PlaybackTime)} to {Clock(target)}");
            PlaybackSeek(target);
        }

        void PlaybackSeek(double seconds)
        {
            if (OnSpatialVideo)
                SpatialVideo.Seek(seconds);
            else
                m_Player.time = seconds;
        }

        void Next()
        {
            if (m_Library.Count > 0)
                Play((Mathf.Max(m_Current, 0) + 1) % m_Library.Count);
        }

        void CycleFormat()
        {
            var entry = Current;
            if (entry == null)
                return;
            // A spatial photo or video already has a picture per eye, so there's no layout to guess.
            if (entry.IsSpatial)
                return;
            entry.Format = entry.Format.Next();
            if (m_Player.isPrepared)
                m_Sphere.Show(m_Texture, entry.Format);
            Debug.Log($"[Video] Format of {entry.Title} set to {entry.Format}");
        }

        void ReleaseTexture()
        {
            if (m_Texture == null)
                return;
            if (m_Player != null && m_Player.targetTexture == m_Texture)
                m_Player.targetTexture = null;
            m_Texture.Release();
            Destroy(m_Texture);
            m_Texture = null;
        }

        // Where the head is looking, in degrees above (+) or below (-) the horizon.
        float HeadPitch => Mathf.Asin(Mathf.Clamp(m_Core.Head.forward.y, -1f, 1f)) * Mathf.Rad2Deg;

        // A tap on the video toggles the controls. It also closes the library, back to the video.
        void OnVideoClicked()
        {
            if (m_ShowingLibrary || m_ControlsShown)
                HidePanel();
            else
                ShowControls();
        }

        void ShowLibrary()
        {
            m_ShowingLibrary = true;
            m_ControlsShown = false;
            m_LibraryPage.gameObject.SetActive(true);
            m_ControlsPage.gameObject.SetActive(false);
            PlacePanel(-12f, k_LibrarySize);
            UpdateLibraryLabels();
        }

        void ShowControls()
        {
            m_ShowingLibrary = false;
            m_ControlsShown = true;
            m_LibraryPage.gameObject.SetActive(false);
            m_ControlsPage.gameObject.SetActive(true);
            PlacePanel(Mathf.Max(HeadPitch - k_ControlsBelowGaze, k_LowestPitch), k_ControlsSize);
            UpdateControls();
        }

        void HidePanel()
        {
            m_ShowingLibrary = false;
            m_ControlsShown = false;
            M3Fade.Hide(m_Panel.gameObject);
        }

        // In front of where the head faces, at a pitch, turned to face it. It stays there until it's
        // hidden and shown again.
        void PlacePanel(float pitch, Vector2 size)
        {
            WorldUi.PlaceInFront(m_Panel, m_Core.Head, k_PanelDistance, pitch);
            m_Panel.sizeDelta = size;
            M3Fade.Show(m_Panel.gameObject);
        }

        void UpdateControls()
        {
            var entry = Current;
            var ready = entry != null && PlaybackReady;
            if (entry != null)
            {
                m_Title.text = entry.Title;
                m_FormatLine.text = entry.Status ?? entry.Format.ToString();
            }
            m_Play.Icon = ready && PlaybackPlaying ? "pause" : "play_arrow";
            m_Time.text = ready ? $"{Clock(PlaybackTime)} / {Clock(PlaybackLength)}" : "";
            m_Seek.Value = ready && PlaybackLength > 0 ? (float)(PlaybackTime / PlaybackLength) : 0f;
        }

        void UpdateLibraryLabels()
        {
            var pages = Mathf.Max(1, (m_Library.Count + k_EntriesPerPage - 1) / k_EntriesPerPage);
            m_Page = Mathf.Clamp(m_Page, 0, pages - 1);
            m_PageLabel.text = $"{m_Page + 1} of {pages}";
            m_PreviousPage.Interactable = m_Page > 0;
            m_NextPage.Interactable = m_Page < pages - 1;
            m_EmptyMessage.gameObject.SetActive(m_Library.Count == 0);
            for (var i = 0; i < m_EntryButtons.Count; i++)
            {
                var index = m_Page * k_EntriesPerPage + i;
                var (item, supporting) = m_EntryButtons[i];
                item.gameObject.SetActive(index < m_Library.Count);
                if (index >= m_Library.Count)
                    continue;
                var entry = m_Library[index];
                item.Text = entry.Title;
                // The library's own spatial items are marked apart from the files, since they
                // arrive without being copied in and are the ones that are 3D.
                item.Icon = entry.NeedsDownload ? "cloud_download" : entry.IsSpatial ? "view_in_ar" : "movie";
                supporting.text = entry.Status ?? (entry.NeedsDownload ? "Google Drive: pinch to download" : entry.Format.ToString());
                if (item.Selected != (index == m_Current))
                    item.Selected = index == m_Current;
            }
        }

        // Both pages share one Material panel, k_PanelDistance away, sized to the page showing. Sizes in dp.
        static readonly Vector2 k_LibrarySize = new(600f, 536f);
        static readonly Vector2 k_ControlsSize = new(600f, 352f);

        void BuildPanel()
        {
            m_Panel = WorldUi.Panel("Video Panel", transform, k_LibrarySize, k_PanelDistance);

            // The library: a list of videos, a page at a time.
            m_LibraryPage = WorldUi.CreateGroup("Library", m_Panel);
            M3.Text("Header", m_LibraryPage, "Videos", M3Theme.Type.TitleLarge, new Vector2(-60f, 220f), new Vector2(432f, 32f),
                alignment: TextAlignmentOptions.Left);
            M3.IconButton("Refresh", m_LibraryPage, "refresh", M3Button.Variant.Text, new Vector2(248f, 220f), () =>
            {
                Refresh();
                UpdateLibraryLabels();
            });
            for (var i = 0; i < k_EntriesPerPage; i++)
            {
                var slot = i;
                m_EntryButtons.Add(M3.ListItem($"Entry {i}", m_LibraryPage, "movie", new Vector2(0f, 152f - i * 68f), 552f,
                    () => Play(m_Page * k_EntriesPerPage + slot)));
            }
            var folder = Application.platform == RuntimePlatform.IPhonePlayer
                ? "On a Mac, open the iPhone in Finder, then Files > CardboardXR > Videos, and drag videos in."
                : $"Copy videos with: adb push video.mp4 {VideoLibrary.VideoFolder}";
            m_EmptyMessage = M3.Text("Empty", m_LibraryPage, "No videos yet.\n\n" + folder +
                "\n\nName tags set the format: _360, _180, _sbs, _tb. For Google Drive, list share links in videos.txt in that folder.",
                M3Theme.Type.BodyMedium, new Vector2(0f, 16f), new Vector2(520f, 300f), M3Theme.OnSurfaceVariant);
            m_PreviousPage = M3.IconButton("Previous page", m_LibraryPage, "chevron_left", M3Button.Variant.Text, new Vector2(-84f, -212f),
                () => Page(-1));
            m_PageLabel = M3.Text("Page", m_LibraryPage, "", M3Theme.Type.BodyMedium, new Vector2(0f, -212f), new Vector2(100f, 24f),
                M3Theme.OnSurfaceVariant);
            m_NextPage = M3.IconButton("Next page", m_LibraryPage, "chevron_right", M3Button.Variant.Text, new Vector2(84f, -212f),
                () => Page(1));

            // The controls: what's playing, a seek slider, transport, then the rest.
            m_ControlsPage = WorldUi.CreateGroup("Controls", m_Panel);
            m_Title = M3.Text("Title", m_ControlsPage, "", M3Theme.Type.TitleMedium, new Vector2(0f, 140f), new Vector2(552f, 24f));
            m_Title.textWrappingMode = TextWrappingModes.NoWrap;
            m_FormatLine = M3.Text("Format", m_ControlsPage, "", M3Theme.Type.BodyMedium, new Vector2(0f, 116f), new Vector2(552f, 20f),
                M3Theme.OnSurfaceVariant);
            m_Seek = M3.Slider("Seek", m_ControlsPage, new Vector2(0f, 76f), 552f);
            m_Seek.Clicked += fraction =>
            {
                if (m_Current >= 0 && PlaybackReady)
                    SeekTo(fraction * PlaybackLength);
            };
            m_Time = M3.Text("Time", m_ControlsPage, "", M3Theme.Type.BodyMedium, new Vector2(0f, 46f), new Vector2(552f, 20f),
                M3Theme.OnSurfaceVariant);

            M3.IconButton("Back 10 s", m_ControlsPage, "replay_10", M3Button.Variant.Tonal, new Vector2(-100f, -20f),
                () => Skip(-k_SkipSeconds));
            m_Play = M3.IconButton("Play", m_ControlsPage, "play_arrow", M3Button.Variant.Filled, new Vector2(0f, -20f), TogglePlay, 80f);
            M3.IconButton("Ahead 10 s", m_ControlsPage, "forward_10", M3Button.Variant.Tonal, new Vector2(100f, -20f),
                () => Skip(k_SkipSeconds));

            const float width = 168f;
            M3.Button("Library", m_ControlsPage, "Library", M3Button.Variant.Tonal, new Vector2(-176f, -128f), ShowLibrary, "video_library",
                width);
            M3.Button("Next video", m_ControlsPage, "Next", M3Button.Variant.Tonal, new Vector2(0f, -128f), Next, "skip_next", width);
            M3.Button("Format", m_ControlsPage, "Format", M3Button.Variant.Tonal, new Vector2(176f, -128f), CycleFormat, "aspect_ratio",
                width);
        }

        void Page(int step)
        {
            m_Page += step;
            UpdateLibraryLabels();
        }

        static string Clock(double seconds)
        {
            var total = (int)System.Math.Max(0.0, seconds);
            return total >= 3600 ? $"{total / 3600}:{total / 60 % 60:00}:{total % 60:00}" : $"{total / 60}:{total % 60:00}";
        }
    }
}
