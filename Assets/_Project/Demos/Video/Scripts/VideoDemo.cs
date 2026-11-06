using System.Collections;
using System.Collections.Generic;
using TMPro;
using Afterglow.UI;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.Video;

namespace Afterglow.Demos.Video
{
    // The media player and its browser: the photos and videos in the phone's Photos library, as a
    // grid of thumbnails filtered by kind (All, Spatial, Panoramas, 360, Videos), and the video
    // files copied to the phone or linked from Google Drive. Pick one and it plays or shows around
    // you: a 360 or VR180 video on the sphere, a panorama on a cylinder as wide as it was swept,
    // a flat photo or film on a screen ahead, and a spatial photo or video with a picture per eye.
    // Pinch (or tap the screen) anywhere on the picture to bring up the controls, a little below
    // where you're looking: play and pause, jump back or ahead 10 s, seek by clicking the bar, the
    // next item, the format (when a file's name or shape doesn't say), and the browser (Home is on
    // the settings panel). Pinch on the picture again to put them away. They stay where they
    // appeared rather than following the head, so they can be looked at.
    // The demo runs in 3DoF with the AR session and hand tracking off; PinchInput's light pinch
    // detector runs, slowing down with no hand in view, leaving most of the heat to the video
    // decoder. Opened from the home screen's Files tile (DemoManager.Argument is
    // HomeScreen.k_FilesArgument) it lists only the files the user copied in or linked, and leaves
    // the Photos library alone. Logs [Video].
    [RequireComponent(typeof(VideoPlayer))]
    public class VideoDemo : Demo
    {
        // The controls appear this far below where the head looks, in degrees, so they don't cover
        // what was being watched, but no lower than k_LowestPitch.
        const float k_ControlsBelowGaze = 20f;
        const float k_LowestPitch = -60f;
        const float k_PanelDistance = 1.5f;
        const float k_SkipSeconds = 10f;
        const float k_StatusSeconds = 5f;
        // The grid: cells of a thumbnail over a name, in dp, and how many a page holds.
        public const int k_Columns = 4;
        public const int k_Rows = 2;
        public const int k_EntriesPerPage = k_Columns * k_Rows;
        const float k_CellWidth = 128f;
        const float k_CellHeight = 118f;
        const float k_ThumbHeight = 92f;
        const float k_Gap = 8f;
        // Thumbnails are asked for at this many pixels across: a cell is 128 dp, and the phone's
        // screen puts about two pixels in a dp through the lens.
        const int k_ThumbnailPixels = 256;
        // How many thumbnails are kept once their page has been left, before the oldest go.
        const int k_ThumbnailCache = 96;
        // A picture is decoded no bigger than this on its longer side: a panorama is wide and
        // deserves more, a photo is seen on a screen that is a fraction of the view.
        const int k_PhotoPixels = 4096;
        const int k_PanoramaPixels = 8192;

        [SerializeField] VideoSphere m_Sphere;
        // The repository's placeholders. Any other videos in StreamingAssets (Tools/make_videos.sh copies
        // your own in for local builds) come first.
        [Tooltip("Videos in StreamingAssets, offered first, so there's something to watch without copying any.")]
        [SerializeField] string[] m_Bundled = { "Sample_360.mp4", "Sample_180_sbs.mp4" };

        CoreServices m_Core;
        VideoPlayer m_Player;
        RenderTexture m_Texture;
        // Everything found, and the part of it under the filter, which is what the grid shows and
        // what Next steps through.
        List<VideoEntry> m_All = new();
        List<VideoEntry> m_Library = new();
        MediaFilter m_Filter = MediaFilter.All;
        // Which album the library part of the list comes from: the whole library, or one picked
        // on the Albums page.
        int m_Album = PhotoLibrary.k_WholeLibrary;
        string m_AlbumTitle;
        PhotoLibrary.Album[] m_Albums = System.Array.Empty<PhotoLibrary.Album>();
        int m_AlbumPage;
        const int k_AlbumRows = 5;
        int m_Current = -1;
        int m_Wanted = -1;
        Coroutine m_Download;
        int m_Dropped;
        float m_NextStatus;
        // The opened picture's eyes (the right one only for a spatial photo).
        Texture2D m_PictureLeft;
        Texture2D m_PictureRight;
        bool m_WaitingForPicture;
        // A spatial video the plugin has open, and whether its first frame has reached the screen.
        bool m_SpatialVideoOpen;
        bool m_SpatialVideoShown;
        // Whether the Photos library question has been settled, either way, so it is asked once.
        bool m_SpatialSettled;
        // Opened as Files: only what the user copied in or linked, and no Photos question.
        bool m_FilesOnly;

        // Thumbnails by item (Key): the request while it loads, then the texture.
        class Thumbnail
        {
            public int Request;
            public Texture2D Texture;
            public bool Failed;
            public int LastShown;
        }

        readonly Dictionary<string, Thumbnail> m_Thumbnails = new();
        Coroutine m_FileImage;
        int m_PageShows;

        RectTransform m_Panel;
        RectTransform m_LibraryPage;
        RectTransform m_ControlsPage;
        TMP_Text m_Header;
        M3Button m_Import;
        M3Button m_AlbumsButton;
        M3Button[] m_Chips;
        RectTransform m_AlbumsPage;
        M3Button[] m_AlbumRows;
        TMP_Text m_AlbumsPageLabel;
        M3Button m_AlbumsPrevious;
        M3Button m_AlbumsNext;
        TMP_Text m_Title;
        TMP_Text m_FormatLine;
        TMP_Text m_Time;
        M3Button m_Play;
        M3Slider m_Seek;
        TMP_Text m_PageLabel;
        M3Button m_PreviousPage;
        M3Button m_NextPage;
        TMP_Text m_EmptyMessage;

        // One cell of the grid.
        class Tile
        {
            public GameObject Root;
            public RawImage Picture;
            public TMP_Text Icon;
            public TMP_Text Badge;
            public GameObject BadgePill;
            public TMP_Text Name;
        }

        readonly List<Tile> m_Tiles = new();
        int m_Page;
        bool m_ShowingLibrary;
        bool m_ControlsShown;
        bool m_ShowingAlbums;

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
            m_FilesOnly = core.Demos != null && core.Demos.Argument == HomeScreen.k_FilesArgument;
            m_Header.text = HeaderText(m_FilesOnly, m_AlbumTitle);
            foreach (var chip in m_Chips)
                chip.gameObject.SetActive(!m_FilesOnly);
            m_Import.gameObject.SetActive(FilePicker.Supported);
            m_AlbumsButton.gameObject.SetActive(!m_FilesOnly && PhotoLibrary.Supported);
            // Put iOS's Photos question up as the demo opens rather than when a photo is picked, so
            // the library can list the user's photos alongside the files straight away.
            m_SpatialSettled = m_FilesOnly || !PhotoLibrary.Supported ||
                               PhotoLibrary.Authorize() != PhotoLibrary.Access.Asking;
            Refresh();
            ShowLibrary();
        }

        public override void OnDemoExit(CoreServices core)
        {
            if (m_Download != null)
                StopCoroutine(m_Download);
            if (m_FileImage != null)
                StopCoroutine(m_FileImage);
            m_Player.prepareCompleted -= OnPrepared;
            m_Player.errorReceived -= OnError;
            m_Player.frameDropped -= OnFrameDropped;
            m_Sphere.Clicked -= OnVideoClicked;
            m_Player.Stop();
            m_Sphere.Show(null, default);
            ReleaseTexture();
            ReleasePicture();
            ReleaseThumbnails();
        }

        void OnDestroy()
        {
            ReleaseTexture();
            ReleasePicture();
            ReleaseThumbnails();
        }

        void Update()
        {
            if (m_Core == null)
                return;
            if (m_WaitingForPicture)
                UpdatePicture();
            if (m_SpatialVideoOpen)
                UpdateSpatialVideo();
            // The Photos question is answered after the demo has opened, so once it is, the library
            // is listed again with the photos in it.
            if (!m_SpatialSettled && PhotoLibrary.Authorize() != PhotoLibrary.Access.Asking)
            {
                m_SpatialSettled = true;
                Refresh();
                if (m_ShowingLibrary)
                    ShowLibrary();
            }

            if (m_ShowingLibrary)
                UpdateThumbnails();
            else if (m_ControlsShown)
                UpdateControls();
            UpdateImports();

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
            m_All = VideoLibrary.Find(m_Bundled, out var bundled, m_FilesOnly ? PhotoLibrary.k_WholeLibrary : m_Album);
            if (m_FilesOnly)
                m_All = VideoLibrary.FilesOnly(m_All, bundled);
            else if (m_Album != PhotoLibrary.k_WholeLibrary)
                m_All = VideoLibrary.LibraryOnly(m_All);
            // Thumbnails belong to library indexes, which a new scan can shift.
            ReleaseThumbnails();
            ApplyFilter(playing);
            m_Page = 0;
            Debug.Log(m_FilesOnly
                ? $"[Video] {m_All.Count} files from {VideoLibrary.VideoFolder}"
                : m_AlbumTitle != null
                    ? $"[Video] {m_All.Count} items in the album {m_AlbumTitle}; {m_Library.Count} under {m_Filter}"
                    : $"[Video] {m_All.Count} items: {bundled} bundled, the files from {VideoLibrary.VideoFolder}, " +
                      $"the rest from the Photos library; {m_Library.Count} under {m_Filter}");
        }

        // What the browser's header says: Files for that section, else the album, else Media.
        // Pure, for testing.
        public static string HeaderText(bool filesOnly, string albumTitle) =>
            filesOnly ? "Files" : string.IsNullOrEmpty(albumTitle) ? "Media" : albumTitle;

        // The Albums page: the library's albums with something in them, All photos first, a page
        // of rows at a time. Picking one lists it in place of the whole library.
        void ShowAlbums()
        {
            m_Albums = PhotoLibrary.Albums();
            m_AlbumPage = 0;
            m_ShowingLibrary = false;
            m_ControlsShown = false;
            m_ShowingAlbums = true;
            m_LibraryPage.gameObject.SetActive(false);
            m_ControlsPage.gameObject.SetActive(false);
            m_AlbumsPage.gameObject.SetActive(true);
            PlacePanel(-12f, k_LibrarySize);
            Debug.Log($"[Video] Albums: {m_Albums.Length} with something in them");
            UpdateAlbumRows();
        }

        // Row 0 of the list is the whole library; the albums follow.
        int AlbumRowCount => m_Albums.Length + 1;

        void UpdateAlbumRows()
        {
            var pages = Mathf.Max(1, (AlbumRowCount + k_AlbumRows - 1) / k_AlbumRows);
            m_AlbumPage = Mathf.Clamp(m_AlbumPage, 0, pages - 1);
            for (var i = 0; i < m_AlbumRows.Length; i++)
            {
                var index = m_AlbumPage * k_AlbumRows + i;
                var row = m_AlbumRows[i];
                row.gameObject.SetActive(index < AlbumRowCount);
                if (index >= AlbumRowCount)
                    continue;
                var whole = index == 0;
                row.Text = whole ? "All photos and videos" : VideoLibrary.AlbumLabel(m_Albums[index - 1].Title, m_Albums[index - 1].Count);
                row.Selected = whole ? m_Album == PhotoLibrary.k_WholeLibrary : m_Albums[index - 1].Index == m_Album;
            }
            m_AlbumsPageLabel.text = pages > 1 ? $"{m_AlbumPage + 1} of {pages}" : "";
            m_AlbumsPrevious.gameObject.SetActive(pages > 1);
            m_AlbumsNext.gameObject.SetActive(pages > 1);
            m_AlbumsPrevious.Interactable = m_AlbumPage > 0;
            m_AlbumsNext.Interactable = m_AlbumPage < pages - 1;
        }

        void PickAlbumRow(int row)
        {
            var index = m_AlbumPage * k_AlbumRows + row;
            if (index >= AlbumRowCount)
                return;
            if (index == 0)
            {
                m_Album = PhotoLibrary.k_WholeLibrary;
                m_AlbumTitle = null;
                Debug.Log("[Video] Album: the whole library");
            }
            else
            {
                var album = m_Albums[index - 1];
                m_Album = album.Index;
                m_AlbumTitle = album.Title;
                Debug.Log($"[Video] Album {album.Title}: {album.Count} items");
            }
            m_Header.text = HeaderText(m_FilesOnly, m_AlbumTitle);
            Refresh();
            ShowLibrary();
        }

        void ApplyFilter(VideoEntry playing)
        {
            m_Library = VideoLibrary.Filter(m_All, m_Filter);
            m_Current = playing == null ? -1 : m_Library.FindIndex(entry => Same(entry, playing));
        }

        // A filter chip: the grid shows that kind from its first page.
        void SetFilter(MediaFilter filter)
        {
            if (filter == m_Filter)
                return;
            m_Filter = filter;
            ApplyFilter(Current);
            m_Page = 0;
            Debug.Log($"[Video] Filter {filter}: {m_Library.Count} items");
            UpdateGrid();
        }

        // What's playing, or null. The library can be rebuilt underneath it (Refresh, and the
        // Photos question being answered after the demo has opened), so the index is never trusted
        // to still be in range.
        VideoEntry Current => m_Current >= 0 && m_Current < m_Library.Count ? m_Library[m_Current] : null;

        // Whether two entries from different scans of the library are the same item. Nothing is
        // shared across the kinds, so one kind is never the same as another.
        //   A library item goes by its title, which is its kind and creation date: its index is a
        // place in a scan of the Photos library, and a scan that picks up a newly taken photo
        // shifts every index after it. A Drive video goes by its file id, which is what it is, and
        // a file by its path.
        public static bool Same(VideoEntry a, VideoEntry b)
        {
            if (a == null || b == null)
                return false;
            if (a.IsLibrary || b.IsLibrary)
                return a.IsLibrary == b.IsLibrary && a.Kind == b.Kind && a.Title == b.Title;
            if (a.DriveId != null || b.DriveId != null)
                return a.DriveId == b.DriveId;
            return a.Url != null && a.Url == b.Url;
        }

        // Opens an entry: a file plays, a Drive video downloads first, a picture is decoded and shown,
        // a library video's file is asked for and then played.
        void Play(int index)
        {
            if (index < 0 || index >= m_Library.Count)
                return;
            var entry = m_Library[index];
            // Picked again while it loads: a big asset in iCloud takes a while, and starting over
            // on every tap meant it never arrived.
            if (index == m_Current && Loading)
            {
                Debug.Log($"[Video] {entry.Title} is still loading{(Progress > 0f ? $" ({Progress:P0})" : "")}");
                return;
            }
            m_Wanted = index;
            if (entry.NeedsDownload)
            {
                if (m_Download == null)
                    m_Download = StartCoroutine(DownloadThenPlay(entry, index));
                return;
            }

            switch (entry.Kind)
            {
                case MediaKind.SpatialPhoto:
                case MediaKind.Photo:
                case MediaKind.Still360:
                case MediaKind.Panorama:
                    OpenPicture(entry, index);
                    return;
                case MediaKind.SpatialVideo:
                case MediaKind.LibraryVideo:
                    PlayLibraryVideo(entry, index);
                    return;
            }
            PlayFile(entry, index);
        }

        // Whether the item picked is still on its way: decoding, downloading or preparing.
        bool Loading => m_WaitingForPicture || (m_SpatialVideoOpen && !m_SpatialVideoShown) || m_FileImage != null ||
                        (Current != null && Current.Status == "Loading" && !m_Player.isPrepared);

        // How far a download from iCloud has got, 0 to 1, for what's loading.
        float Progress => m_WaitingForPicture ? PhotoLibrary.Progress : m_SpatialVideoOpen ? SpatialVideo.Progress : 0f;

        // Stops whatever was showing, so nothing is drawn from buffers about to go.
        void StopShowing()
        {
            m_Player.Stop();
            // Off the screen before the pictures go: a spatial video's textures are views of the
            // decoder's own memory, and one left on the quad would be drawn from freed buffers.
            m_Sphere.Show(null, default);
            ReleasePicture();
        }

        void PlayFile(VideoEntry entry, int index)
        {
            StopShowing();
            m_Current = index;
            m_Player.url = entry.Url;
            m_Player.Prepare();
            m_Title.text = entry.Title;
            entry.Status = "Loading";
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Format})");
            ShowControls();
        }

        // A picture is decoded by the plugin off the main thread, and Update picks it up when it's
        // ready: a spatial photo as two pictures, anything else as one.
        void OpenPicture(VideoEntry entry, int index)
        {
            StopShowing();
            m_Current = index;
            m_Title.text = entry.Title;

            if (entry.IsLibrary && PhotoLibrary.Authorize() != PhotoLibrary.Access.Granted)
            {
                entry.Status = "Allow Photos to show this";
                Debug.Log("[Video] The Photos library isn't allowed yet, so the picture stays shut");
                return;
            }
            var pixels = entry.Kind == MediaKind.Panorama ? k_PanoramaPixels : k_PhotoPixels;
            bool ok;
            if (!entry.IsLibrary)
            {
                // A file of the app's own: the plugin decodes it on iOS; elsewhere Unity reads a
                // JPEG or PNG itself, and a HEIC has to wait for the phone.
                ok = PhotoLibrary.OpenFile(entry.Url, pixels);
                if (!ok && !PhotoLibrary.Supported && IsUnityDecodable(entry.Url))
                {
                    if (m_FileImage != null)
                        StopCoroutine(m_FileImage);
                    m_FileImage = StartCoroutine(LoadFileImage(entry, index));
                    return;
                }
                if (!ok)
                {
                    m_Current = -1;
                    entry.Status = PhotoLibrary.Supported ? "Couldn't open that picture" : "HEIC pictures need the phone";
                    Debug.LogWarning($"[Video] Couldn't open {entry.Title}: {entry.Status}");
                    ShowLibrary();
                    return;
                }
            }
            else
            {
                ok = entry.Kind == MediaKind.SpatialPhoto
                    ? PhotoLibrary.OpenSpatialPhoto(entry.LibraryIndex)
                    : PhotoLibrary.OpenImage(entry.LibraryIndex, pixels);
            }
            if (!ok)
            {
                m_Current = -1;
                entry.Status = "Couldn't open that picture";
                Debug.LogWarning($"[Video] Couldn't open {entry.Title}");
                ShowLibrary();
                return;
            }
            entry.Status = "Loading";
            m_WaitingForPicture = true;
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Width}x{entry.Height})");
            ShowControls();
        }

        // Polled while a picture loads.
        void UpdatePicture()
        {
            switch (PhotoLibrary.PhotoState)
            {
                case PhotoLibrary.State.Loading:
                    return;
                case PhotoLibrary.State.Ready:
                    m_WaitingForPicture = false;
                    if (!PhotoLibrary.TryTakeTextures(out m_PictureLeft, out m_PictureRight))
                    {
                        FailPicture("That picture couldn't be uploaded");
                        return;
                    }
                    var entry = Current;
                    if (entry == null)
                    {
                        ReleasePicture();
                        return;
                    }
                    if (entry.Kind == MediaKind.SpatialPhoto && m_PictureRight == null)
                    {
                        FailPicture("That spatial photo gave only one eye");
                        return;
                    }
                    // A file the library didn't mark as spatial turned out to hold a pair.
                    if (m_PictureRight != null && entry.Kind != MediaKind.SpatialPhoto)
                    {
                        entry.Kind = MediaKind.SpatialPhoto;
                        entry.Format = VideoFormat.Stereo3D;
                    }
                    SizeFromPicture(entry);
                    ShowPicture(entry);
                    entry.Status = null;
                    Debug.Log($"[Video] {VideoLibrary.Describe(entry.Kind)} shown: {m_PictureLeft.width}x{m_PictureLeft.height}" +
                              (m_PictureRight != null ? " per eye" : "") +
                              (entry.Kind == MediaKind.Panorama ? $", {PanoramaDegrees(entry):F0} degrees round" : ""));
                    HidePanel();
                    // The pictures are in textures now, so the plugin needn't keep its buffers.
                    PhotoLibrary.Close();
                    return;
                default:
                    FailPicture(PhotoLibrary.PhotoError);
                    return;
            }
        }

        // A file whose size wasn't known until it was decoded: now it is, and so is its kind.
        void SizeFromPicture(VideoEntry entry)
        {
            if (m_PictureLeft == null || (entry.Width > 0 && entry.Height > 0))
                return;
            entry.Width = m_PictureLeft.width;
            entry.Height = m_PictureLeft.height;
            if (entry.IsSpatial)
                return;
            entry.Kind = VideoLibrary.Classify(false, false, false, entry.Width, entry.Height);
            entry.Format = VideoLibrary.DefaultFormat(entry.Kind, entry.Width, entry.Height);
        }

        // Unity's own decoder reads JPEG and PNG, for the Editor and Android.
        static bool IsUnityDecodable(string path)
        {
            var extension = System.IO.Path.GetExtension(path ?? "").ToLowerInvariant();
            return extension == ".jpg" || extension == ".jpeg" || extension == ".png";
        }

        // A JPEG or PNG file read by Unity, where the plugin isn't there. The read is on the main
        // thread, which is a stall for a big file, but that's the Editor and Android for now.
        IEnumerator LoadFileImage(VideoEntry entry, int index)
        {
            entry.Status = "Loading";
            yield return null;
            m_FileImage = null;
            if (m_Wanted != index)
                yield break;
            Texture2D texture = null;
            try
            {
                var bytes = System.IO.File.ReadAllBytes(entry.Url);
                texture = new Texture2D(2, 2, TextureFormat.RGBA32, false) { name = "Photo File", wrapMode = TextureWrapMode.Clamp };
                if (!texture.LoadImage(bytes, true))
                {
                    Destroy(texture);
                    texture = null;
                }
            }
            catch (System.Exception e) when (e is System.IO.IOException or System.UnauthorizedAccessException)
            {
                Debug.LogWarning($"[Video] Couldn't read {entry.Url}: {e.Message}");
            }
            if (texture == null)
            {
                FailPicture("That picture couldn't be read");
                yield break;
            }
            ReleasePicture();
            m_PictureLeft = texture;
            SizeFromPicture(entry);
            ShowPicture(entry);
            entry.Status = null;
            Debug.Log($"[Video] {VideoLibrary.Describe(entry.Kind)} shown: {texture.width}x{texture.height}, read by Unity");
            HidePanel();
        }

        // Opens iOS's picker; what it imports shows up in the grid as it lands (UpdateImports).
        void Import()
        {
            if (!FilePicker.Present(VideoLibrary.MediaFolder))
            {
                Debug.Log("[Video] The picker couldn't open");
                return;
            }
            Debug.Log("[Video] Importing from Files");
        }

        void UpdateImports()
        {
            var imported = 0;
            while (FilePicker.TryTake(out var path) == FilePicker.Result.Imported)
            {
                imported++;
                Debug.Log($"[Video] Imported {System.IO.Path.GetFileName(path)}");
            }
            if (imported == 0)
                return;
            Refresh();
            if (m_ShowingLibrary)
                UpdateGrid();
        }

        // Draws the opened picture the way its kind says, and again when the user changes the kind.
        void ShowPicture(VideoEntry entry)
        {
            if (m_PictureLeft == null)
                return;
            if (m_PictureRight != null)
                m_Sphere.Show(m_PictureLeft, VideoFormat.Stereo3D, m_PictureRight);
            else if (entry.Kind == MediaKind.Panorama)
                m_Sphere.ShowPanorama(m_PictureLeft, PanoramaDegrees(entry), VideoLibrary.PanoramaHeightDegrees(entry));
            else
                m_Sphere.Show(m_PictureLeft, entry.Format);
        }

        float PanoramaDegrees(VideoEntry entry) =>
            VideoLibrary.PanoramaDegrees(entry, m_PictureLeft != null ? m_PictureLeft.width : 0,
                m_PictureLeft != null ? m_PictureLeft.height : 0);

        // A library video doesn't go through VideoPlayer: Unity's player can't open a file in
        // the Photos library, and a spatial one it would decode flat, one of the file's two layers.
        // The plugin plays it with AVFoundation, both views when there are two, and keeps the clock
        // and the audio, so the controls ask it rather than VideoPlayer (see OnPluginVideo), and
        // Update picks up each frame's picture or pictures. iOS 18 and later.
        void PlayLibraryVideo(VideoEntry entry, int index)
        {
            StopShowing();
            m_Current = index;
            m_Title.text = entry.Title;

            if (PhotoLibrary.Authorize() != PhotoLibrary.Access.Granted)
            {
                entry.Status = "Allow Photos to show this";
                Debug.Log("[Video] The Photos library isn't allowed yet, so the video stays shut");
                return;
            }
            if (!SpatialVideo.Supported)
            {
                entry.Status = "Library videos need iOS 18";
                Debug.LogWarning($"[Video] Couldn't open {entry.Title}: {entry.Status}");
                m_Current = -1;
                ShowLibrary();
                return;
            }
            if (!SpatialVideo.Open(entry.LibraryIndex))
            {
                var why = SpatialVideo.Error;
                m_Current = -1;
                entry.Status = string.IsNullOrEmpty(why) ? "Couldn't open that video" : why;
                Debug.LogWarning($"[Video] Couldn't open {entry.Title}: {entry.Status}");
                ShowLibrary();
                return;
            }
            entry.Status = "Loading";
            m_SpatialVideoOpen = true;
            Debug.Log($"[Video] Opening {entry.Title} ({entry.Format})");
            ShowControls();
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
                    var entry = Current;
                    // Two views are a spatial video on the screen, one view is drawn the way the
                    // entry's format says (flat, or 360 for a 2:1 one).
                    if (SpatialVideo.Stereo)
                        m_Sphere.Show(SpatialVideo.Left, VideoFormat.Stereo3D, SpatialVideo.Right);
                    else
                        m_Sphere.Show(SpatialVideo.Left, entry != null ? entry.Format : new VideoFormat(Projection.Flat, StereoLayout.Mono));
                    if (m_SpatialVideoShown)
                        return;
                    m_SpatialVideoShown = true;
                    if (entry != null)
                        entry.Status = SpatialVideo.Stereo || entry.Kind != MediaKind.SpatialVideo
                            ? null : "One eye only: that file holds a single view";
                    Debug.Log($"[Video] Library video playing: {SpatialVideo.Left.width}x{SpatialVideo.Left.height}" +
                              $"{(SpatialVideo.Stereo ? " per eye, both eyes" : ", one view")}, {Clock(PlaybackLength)}");
                    HidePanel();
                    return;
                default:
                    FailPicture(SpatialVideo.Error);
                    return;
            }
        }

        void FailPicture(string message)
        {
            var kind = Current != null ? VideoLibrary.Describe(Current.Kind).ToLowerInvariant() : "picture";
            if (Current != null)
                Current.Status = string.IsNullOrEmpty(message) ? $"Couldn't show that {kind}" : message;
            Debug.LogWarning($"[Video] {kind} failed: {(string.IsNullOrEmpty(message) ? "no reason given" : message)}");
            m_Current = -1;
            m_Sphere.Show(null, default);
            ReleasePicture();
            ShowLibrary();
        }

        void ReleasePicture()
        {
            m_WaitingForPicture = false;
            m_SpatialVideoOpen = false;
            m_SpatialVideoShown = false;
            PhotoLibrary.Close();
            // Closing lets go of the decoder's buffers, and with them the textures that were views
            // of them, so nothing is left pointing into freed memory.
            SpatialVideo.Close();
            if (m_PictureLeft != null)
                Destroy(m_PictureLeft);
            if (m_PictureRight != null)
                Destroy(m_PictureRight);
            m_PictureLeft = m_PictureRight = null;
        }

        // Whatever is playing, asked through one set of questions rather than a branch at every
        // button. A file goes through Unity's VideoPlayer and a spatial video through the plugin;
        // a picture has no clock at all, and VideoPlayer, stopped, answers for it as a still.
        bool OnSpatialVideo => Current is { IsSpatialVideo: true } or { Kind: MediaKind.LibraryVideo };

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

        // The Format button: for a video, the next layout; for a picture from the library, the next
        // way of wrapping it (a screen, all the way round, a panorama), since the shape it was
        // guessed from can mislead. A spatial photo or video already has a picture per eye, so
        // there's no layout to guess.
        void CycleFormat()
        {
            var entry = Current;
            if (entry == null || entry.IsSpatial)
                return;
            if (entry.IsPicture)
            {
                entry.Kind = entry.Kind switch
                {
                    MediaKind.Photo => MediaKind.Still360,
                    MediaKind.Still360 => MediaKind.Panorama,
                    _ => MediaKind.Photo,
                };
                entry.Format = VideoLibrary.DefaultFormat(entry.Kind, entry.Width, entry.Height);
                ShowPicture(entry);
                Debug.Log($"[Video] {entry.Title} shown as {VideoLibrary.Describe(entry.Kind).ToLowerInvariant()}");
                return;
            }
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

        void OnVideoClicked()
        {
            Debug.Log($"[Video] Picture clicked with the panel {(m_ShowingLibrary ? "on the browser" : m_ControlsShown ? "on the controls" : m_ShowingAlbums ? "on the albums" : "away")}");
            if (m_ShowingLibrary || m_ControlsShown || m_ShowingAlbums)
                HidePanel();
            else
                ShowControls();
        }

        void ShowLibrary()
        {
            m_ShowingLibrary = true;
            m_ControlsShown = false;
            m_ShowingAlbums = false;
            m_LibraryPage.gameObject.SetActive(true);
            m_ControlsPage.gameObject.SetActive(false);
            m_AlbumsPage.gameObject.SetActive(false);
            PlacePanel(-12f, k_LibrarySize);
            UpdateGrid();
        }

        void ShowControls()
        {
            m_ShowingLibrary = false;
            m_ControlsShown = true;
            m_ShowingAlbums = false;
            m_LibraryPage.gameObject.SetActive(false);
            m_ControlsPage.gameObject.SetActive(true);
            m_AlbumsPage.gameObject.SetActive(false);
            PlacePanel(Mathf.Max(HeadPitch - k_ControlsBelowGaze, k_LowestPitch), k_ControlsSize);
            UpdateControls();
            Debug.Log($"[Video] Controls shown at {m_Panel.position}, head at {m_Core.Head.position} pitch {HeadPitch:F0}, " +
                      $"panel {(m_Panel.gameObject.activeInHierarchy ? "active" : "inactive")}");
        }

        void HidePanel()
        {
            m_ShowingLibrary = false;
            m_ControlsShown = false;
            m_ShowingAlbums = false;
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

        float HeadPitch
        {
            get
            {
                var forward = m_Core.Head.forward;
                return Mathf.Asin(Mathf.Clamp(forward.y, -1f, 1f)) * Mathf.Rad2Deg;
            }
        }

        // What the controls say about the item: its state while something is wrong, else its kind
        // and shape.
        static string Describe(VideoEntry entry)
        {
            if (entry.Status != null && entry.Status != "Loading")
                return entry.Status;
            return entry.Kind switch
            {
                MediaKind.Panorama => $"Panorama, {VideoLibrary.PanoramaDegrees(entry):F0}°",
                MediaKind.Still360 => "360 still",
                MediaKind.Photo => "Photo",
                MediaKind.SpatialPhoto => "Spatial photo",
                MediaKind.SpatialVideo => "Spatial video",
                _ => entry.Format.ToString(),
            };
        }

        void UpdateControls()
        {
            var entry = Current;
            var ready = entry != null && PlaybackReady;
            if (entry != null)
            {
                m_Title.text = entry.Title;
                m_FormatLine.text = Describe(entry);
            }
            m_Play.Icon = ready && PlaybackPlaying ? "pause" : "play_arrow";
            var progress = Progress;
            m_Time.text = ready ? $"{Clock(PlaybackTime)} / {Clock(PlaybackLength)}"
                : Loading ? (progress > 0f ? $"Downloading from iCloud, {progress:P0}" : "Loading…") : "";
            // The seek bar stands in for a progress bar until there is something to seek.
            m_Seek.Value = ready && PlaybackLength > 0 ? (float)(PlaybackTime / PlaybackLength) : Loading ? progress : 0f;
        }

        // The icon on a tile, for what the thumbnail doesn't show.
        static string Icon(VideoEntry entry) => entry.Kind switch
        {
            MediaKind.SpatialPhoto => "view_in_ar",
            MediaKind.SpatialVideo => "view_in_ar",
            MediaKind.Panorama => "panorama",
            MediaKind.Still360 => "360",
            MediaKind.Photo => "photo",
            MediaKind.Drive => entry.NeedsDownload ? "cloud_download" : "movie",
            _ => "movie",
        };

        // Fills the page's tiles from the filtered list, asking for the thumbnails it lacks.
        void UpdateGrid()
        {
            var pages = Mathf.Max(1, (m_Library.Count + k_EntriesPerPage - 1) / k_EntriesPerPage);
            m_Page = Mathf.Clamp(m_Page, 0, pages - 1);
            m_PageLabel.text = $"{m_Page + 1} of {pages}";
            m_PreviousPage.Interactable = m_Page > 0;
            m_NextPage.Interactable = m_Page < pages - 1;
            m_EmptyMessage.gameObject.SetActive(m_Library.Count == 0);
            m_EmptyMessage.text = EmptyMessage();
            for (var i = 0; i < m_Chips.Length; i++)
                m_Chips[i].Selected = (MediaFilter)i == m_Filter;
            m_PageShows++;
            for (var i = 0; i < m_Tiles.Count; i++)
            {
                var index = m_Page * k_EntriesPerPage + i;
                var tile = m_Tiles[i];
                tile.Root.SetActive(index < m_Library.Count);
                if (index >= m_Library.Count)
                    continue;
                var entry = m_Library[index];
                tile.Name.text = entry.Title;
                tile.Name.color = index == m_Current ? M3Theme.Primary : M3Theme.OnSurface;
                tile.Icon.text = M3Icons.Glyph(Icon(entry));
                var video = entry.IsVideo && entry.Seconds > 0;
                tile.BadgePill.SetActive(entry.IsLibrary);
                tile.Badge.text = video ? Clock(entry.Seconds) : M3Icons.Glyph(Icon(entry));
                tile.Badge.font = video ? M3Assets.Instance.Medium : M3Assets.Instance.Icons;
                SetThumbnail(tile, Thumb(entry));
            }
            TrimThumbnails();
        }

        string EmptyMessage()
        {
            if (m_FilesOnly || m_All.Count == 0)
            {
                var folder = Application.platform == RuntimePlatform.IPhonePlayer
                    ? "Import brings photos and videos in from Files. Or, on a Mac, open the iPhone in Finder, then Files > Afterglow > Media, and drag them in."
                    : $"Copy photos and videos with: adb push video.mp4 {VideoLibrary.MediaFolder}";
                return "No files yet.\n\n" + folder +
                       "\n\nName tags set a video's format: _360, _180, _sbs, _tb. For Google Drive, list share links in videos.txt in that folder.";
            }
            if (PhotoLibrary.Supported && PhotoLibrary.Authorize() != PhotoLibrary.Access.Granted)
                return "Allow Photos in Settings to see your photos and videos here.";
            if (m_AlbumTitle != null)
                return $"Nothing in {m_AlbumTitle} under {m_Filter}.";
            return m_Filter switch
            {
                MediaFilter.Spatial => "No spatial photos or videos. An iPhone 15 Pro or later takes them in the Camera app's Spatial mode.",
                MediaFilter.Panoramas => "No panoramas in the library.",
                MediaFilter.Still360 => "Nothing 360 here: a 2:1 still, or a video whose name or shape says 360 or 180.",
                MediaFilter.Videos => "No videos in the library or the Videos folder.",
                _ => "Nothing to show yet.",
            };
        }

        // What a thumbnail is filed under: the library index, or the file's path. Null for an
        // entry that has no picture to ask for (a Drive link not yet downloaded).
        public static string Key(VideoEntry entry)
        {
            if (entry.IsLibrary)
                return $"library:{entry.LibraryIndex}";
            return entry.Url != null ? $"file:{entry.Url}" : null;
        }

        // The thumbnail for an item, asking for it the first time: the library's for a library
        // item, the plugin's for a file.
        Thumbnail Thumb(VideoEntry entry)
        {
            var key = Key(entry);
            if (key == null)
                return null;
            if (!m_Thumbnails.TryGetValue(key, out var thumb))
            {
                thumb = new Thumbnail
                {
                    Request = entry.IsLibrary
                        ? PhotoLibrary.RequestThumbnail(entry.LibraryIndex, k_ThumbnailPixels)
                        : PhotoLibrary.RequestFileThumbnail(entry.Url, k_ThumbnailPixels),
                };
                thumb.Failed = thumb.Request == 0;
                m_Thumbnails[key] = thumb;
            }
            thumb.LastShown = m_PageShows;
            return thumb;
        }

        // Puts a thumbnail on a tile, or the kind's icon while there isn't one.
        static void SetThumbnail(Tile tile, Thumbnail thumb)
        {
            var texture = thumb?.Texture;
            tile.Picture.texture = texture;
            tile.Picture.gameObject.SetActive(texture != null);
            tile.Icon.gameObject.SetActive(texture == null);
            if (texture != null)
                tile.Picture.uvRect = CoverRect(texture.width, texture.height, k_CellWidth, k_ThumbHeight);
        }

        // The part of a picture that fills a frame of another shape, cropped evenly from the sides
        // that overhang. Pure, for testing.
        public static Rect CoverRect(float width, float height, float frameWidth, float frameHeight)
        {
            if (width <= 0f || height <= 0f || frameWidth <= 0f || frameHeight <= 0f)
                return new Rect(0f, 0f, 1f, 1f);
            var picture = width / height;
            var frame = frameWidth / frameHeight;
            if (picture > frame)
            {
                var w = frame / picture;
                return new Rect((1f - w) / 2f, 0f, w, 1f);
            }
            var h = picture / frame;
            return new Rect(0f, (1f - h) / 2f, 1f, h);
        }

        // Collects thumbnails that have arrived and puts them on the tiles showing them.
        void UpdateThumbnails()
        {
            foreach (var (key, thumb) in m_Thumbnails)
            {
                if (thumb.Texture != null || thumb.Failed || thumb.Request == 0)
                    continue;
                var state = PhotoLibrary.TryTakeThumbnail(thumb.Request, out var texture);
                if (state == PhotoLibrary.State.Loading)
                    continue;
                thumb.Request = 0;
                if (state == PhotoLibrary.State.Failed)
                {
                    thumb.Failed = true;
                    continue;
                }
                thumb.Texture = texture;
                for (var i = 0; i < m_Tiles.Count; i++)
                {
                    var index = m_Page * k_EntriesPerPage + i;
                    if (index < m_Library.Count && Key(m_Library[index]) == key)
                        SetThumbnail(m_Tiles[i], thumb);
                }
            }
        }

        // Lets the oldest thumbnails go once there are more than a few pages' worth.
        void TrimThumbnails()
        {
            if (m_Thumbnails.Count <= k_ThumbnailCache)
                return;
            var stale = new List<string>();
            foreach (var (key, thumb) in m_Thumbnails)
            {
                if (thumb.LastShown != m_PageShows)
                    stale.Add(key);
            }
            stale.Sort((a, b) => m_Thumbnails[a].LastShown.CompareTo(m_Thumbnails[b].LastShown));
            for (var i = 0; i < stale.Count && m_Thumbnails.Count > k_ThumbnailCache; i++)
            {
                ReleaseThumbnail(m_Thumbnails[stale[i]]);
                m_Thumbnails.Remove(stale[i]);
            }
        }

        static void ReleaseThumbnail(Thumbnail thumb)
        {
            if (thumb.Request != 0)
                PhotoLibrary.ReleaseThumbnail(thumb.Request);
            if (thumb.Texture != null)
                Destroy(thumb.Texture);
            thumb.Request = 0;
            thumb.Texture = null;
        }

        void ReleaseThumbnails()
        {
            foreach (var thumb in m_Thumbnails.Values)
                ReleaseThumbnail(thumb);
            m_Thumbnails.Clear();
            foreach (var tile in m_Tiles)
                SetThumbnail(tile, null);
        }

        // Both pages share one Material panel, k_PanelDistance away, sized to the page showing. Sizes in dp.
        static readonly Vector2 k_LibrarySize = new(600f, 452f);
        static readonly Vector2 k_ControlsSize = new(600f, 352f);

        void BuildPanel()
        {
            m_Panel = WorldUi.Panel("Video Panel", transform, k_LibrarySize, k_PanelDistance);
            var top = k_LibrarySize.y / 2f - 16f;

            // The browser: a header, the filter chips, a grid of thumbnails, and the page controls.
            m_LibraryPage = WorldUi.CreateGroup("Library", m_Panel);
            m_Header = M3.Text("Header", m_LibraryPage, "Media", M3Theme.Type.TitleLarge, new Vector2(-144f, top - 16f), new Vector2(264f, 32f),
                alignment: TextAlignmentOptions.Left);
            m_Header.textWrappingMode = TextWrappingModes.NoWrap;
            m_Header.overflowMode = TextOverflowModes.Ellipsis;
            // Albums lists the library's albums to pick from; hidden without a library.
            m_AlbumsButton = M3.IconButton("Albums", m_LibraryPage, "photo_library", M3Button.Variant.Text, new Vector2(52f, top - 16f), ShowAlbums, 48f);
            // Import opens iOS's Files picker; hidden where there is none.
            m_Import = M3.Button("Import", m_LibraryPage, "Import", M3Button.Variant.Tonal, new Vector2(150f, top - 16f), Import, "add", 124f);
            M3.IconButton("Refresh", m_LibraryPage, "refresh", M3Button.Variant.Text, new Vector2(248f, top - 16f), () =>
            {
                Refresh();
                UpdateGrid();
            });
            var chipsY = top - 32f - 8f - 20f;
            m_Chips = M3.Segments("Filters", m_LibraryPage, new[] { "All", "Spatial", "Panoramas", "360", "Videos" },
                new Vector2(0f, chipsY), 104f, index => SetFilter((MediaFilter)index));

            var gridTop = chipsY - 20f - k_Gap;
            for (var i = 0; i < k_EntriesPerPage; i++)
            {
                var column = i % k_Columns;
                var row = i / k_Columns;
                var x = -k_LibrarySize.x / 2f + 16f + k_CellWidth / 2f + column * (k_CellWidth + k_Gap);
                var y = gridTop - k_CellHeight / 2f - row * (k_CellHeight + k_Gap);
                var slot = i;
                m_Tiles.Add(BuildTile(i, new Vector2(x, y), () => Play(m_Page * k_EntriesPerPage + slot)));
            }
            var gridBottom = gridTop - k_Rows * k_CellHeight - (k_Rows - 1) * k_Gap;
            m_EmptyMessage = M3.Text("Empty", m_LibraryPage, "", M3Theme.Type.BodyMedium,
                new Vector2(0f, (gridTop + gridBottom) / 2f), new Vector2(520f, gridTop - gridBottom - 16f), M3Theme.OnSurfaceVariant);
            var footerY = -k_LibrarySize.y / 2f + 16f + 24f;
            m_PreviousPage = M3.IconButton("Previous page", m_LibraryPage, "chevron_left", M3Button.Variant.Text, new Vector2(-84f, footerY),
                () => Page(-1), 48f);
            m_PageLabel = M3.Text("Page", m_LibraryPage, "", M3Theme.Type.BodyMedium, new Vector2(0f, footerY), new Vector2(100f, 24f),
                M3Theme.OnSurfaceVariant);
            m_NextPage = M3.IconButton("Next page", m_LibraryPage, "chevron_right", M3Button.Variant.Text, new Vector2(84f, footerY),
                () => Page(1), 48f);

            // The albums: a header with the way back, a page of rows, and the page controls.
            m_AlbumsPage = WorldUi.CreateGroup("Albums", m_Panel);
            M3.IconButton("Back", m_AlbumsPage, "arrow_back", M3Button.Variant.Text, new Vector2(-k_LibrarySize.x / 2f + 16f + 24f, top - 16f),
                ShowLibrary, 48f);
            M3.Text("Albums Header", m_AlbumsPage, "Albums", M3Theme.Type.TitleLarge, new Vector2(0f, top - 16f), new Vector2(400f, 32f));
            m_AlbumRows = new M3Button[k_AlbumRows];
            var rowTop = top - 32f - 12f - 20f;
            for (var i = 0; i < k_AlbumRows; i++)
            {
                var row = i;
                m_AlbumRows[i] = M3.Button($"Album {i}", m_AlbumsPage, "", M3Button.Variant.Segment, new Vector2(0f, rowTop - i * 60f),
                    () => PickAlbumRow(row), null, 552f);
            }
            m_AlbumsPrevious = M3.IconButton("Previous albums", m_AlbumsPage, "chevron_left", M3Button.Variant.Text, new Vector2(-84f, footerY),
                () => { m_AlbumPage--; UpdateAlbumRows(); }, 48f);
            m_AlbumsPageLabel = M3.Text("Albums Page", m_AlbumsPage, "", M3Theme.Type.BodyMedium, new Vector2(0f, footerY), new Vector2(100f, 24f),
                M3Theme.OnSurfaceVariant);
            m_AlbumsNext = M3.IconButton("Next albums", m_AlbumsPage, "chevron_right", M3Button.Variant.Text, new Vector2(84f, footerY),
                () => { m_AlbumPage++; UpdateAlbumRows(); }, 48f);
            m_AlbumsPage.gameObject.SetActive(false);

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
            M3.Button("Library", m_ControlsPage, "Browse", M3Button.Variant.Tonal, new Vector2(-176f, -128f), ShowLibrary, "video_library",
                width);
            M3.Button("Next video", m_ControlsPage, "Next", M3Button.Variant.Tonal, new Vector2(0f, -128f), Next, "skip_next", width);
            M3.Button("Format", m_ControlsPage, "Format", M3Button.Variant.Tonal, new Vector2(176f, -128f), CycleFormat, "aspect_ratio",
                width);
        }

        // One cell: a rounded frame holding the thumbnail (or the kind's icon until it arrives),
        // a badge in its corner saying what it is, and the name under it; the whole cell the
        // target, with a state layer for the gaze.
        Tile BuildTile(int index, Vector2 position, UnityEngine.Events.UnityAction onClick)
        {
            var cell = M3.Group($"Tile {index}", m_LibraryPage, position, new Vector2(k_CellWidth, k_CellHeight));
            var state = M3.Surface("State Layer", cell, Vector2.zero, cell.sizeDelta, Color.clear, M3Theme.k_ShapeLarge, raycastTarget: true);
            var button = cell.gameObject.AddComponent<Button>();
            button.transition = Selectable.Transition.None;
            button.targetGraphic = state;
            button.onClick.AddListener(onClick);
            cell.gameObject.AddComponent<M3StateLayer>().Initialize(state, button, M3Theme.OnSurface);

            var frameY = k_CellHeight / 2f - k_ThumbHeight / 2f;
            var frame = M3.Surface("Frame", cell, new Vector2(0f, frameY), new Vector2(k_CellWidth, k_ThumbHeight),
                M3Theme.SurfaceContainerHighest, M3Theme.k_ShapeCard);
            // The frame's rounded shape clips the picture to it.
            frame.gameObject.AddComponent<Mask>().showMaskGraphic = true;
            var pictureObject = new GameObject("Picture", typeof(RectTransform), typeof(RawImage));
            var pictureRect = (RectTransform)pictureObject.transform;
            pictureRect.SetParent(frame.rectTransform, false);
            pictureRect.anchorMin = Vector2.zero;
            pictureRect.anchorMax = Vector2.one;
            pictureRect.offsetMin = pictureRect.offsetMax = Vector2.zero;
            var picture = pictureObject.GetComponent<RawImage>();
            picture.raycastTarget = false;
            pictureObject.SetActive(false);
            var icon = M3.Icon("Icon", cell, "movie", 36f, new Vector2(0f, frameY), M3Theme.OnSurfaceVariant);

            // The badge: a dark pill in the frame's corner with the kind's icon, or a video's length.
            var pill = M3.Surface("Badge", cell, new Vector2(-k_CellWidth / 2f + 6f + 22f, frameY - k_ThumbHeight / 2f + 6f + 10f),
                new Vector2(44f, 20f), M3Theme.WithAlpha(Color.black, 0.6f), M3Theme.k_ShapeFull);
            var badge = M3.Text("Label", pill.rectTransform, "", M3Theme.Type.LabelLarge, Vector2.zero, new Vector2(44f, 20f), Color.white);
            badge.fontSize = 14f;
            pill.gameObject.SetActive(false);

            var name = M3.Text("Name", cell, "", M3Theme.Type.BodyMedium, new Vector2(0f, -k_CellHeight / 2f + 10f),
                new Vector2(k_CellWidth - 4f, 20f));
            name.textWrappingMode = TextWrappingModes.NoWrap;
            name.overflowMode = TextOverflowModes.Ellipsis;
            return new Tile { Root = cell.gameObject, Picture = picture, Icon = icon, Badge = badge, BadgePill = pill.gameObject, Name = name };
        }

        void Page(int step)
        {
            m_Page += step;
            UpdateGrid();
        }

        static string Clock(double seconds)
        {
            var total = (int)System.Math.Max(0.0, seconds);
            return total >= 3600 ? $"{total / 3600}:{total / 60 % 60:00}:{total % 60:00}" : $"{total / 60}:{total % 60:00}";
        }
    }
}
