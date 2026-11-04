// Spatial video from the user's Photos library: both eyes of an MV-HEVC file, as Metal textures
// Unity draws from without ever copying the pixels. SpatialVideo.cs is the C# side, and
// CardboardXRSpatialPhotos.mm owns the library scan whose indexes this takes.
//
// An iPhone 15 Pro and later record a spatial video as one MV-HEVC track whose two views are
// separate layers. An ordinary decode hands back one layer -- whichever the file calls the hero eye
// -- and silently drops the other, so the video plays flat with nothing saying the 3D has gone.
// That is why the library used to leave these out. To get both layers the decoder has to be asked
// for both, and the frames then arrive grouped rather than one at a time.
//
// The asking is done with AVPlayerVideoOutput: an output attached to an ordinary AVPlayer, carrying
// a tag collection that says "two stereo views". The player keeps the clock, the audio, seeking and
// looping; each frame is pulled out of the output as a CMTaggedBufferGroup and the eyes are looked
// up by stereo eye rather than by layer number, so whichever layer is the hero and whichever order
// the file stores them in, left comes back as left. A file that turns out to hold one view falls
// back to the monoscopic collection and is reported as not stereo, rather than passed off as 3D.
//
// Nothing is copied. Each eye's CVPixelBuffer is wrapped as a Metal texture on Unity's own device
// and handed to C# as an external texture. Copying instead would be around half a gigabyte a second
// at 1080p per eye, on a phone sealed in a viewer that is already drawing the whole scene twice.
//
// Needs iOS 18: the output settings that ask for BGRA arrived there, and the iOS 17.2 way of asking
// is deprecated. Spatial video is for an iPhone 15 Pro and later, all of which can run iOS 18.

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#include <atomic>
#include <math.h>

// Unity's own Metal device, from its trampoline (Classes/UnityAppController+Rendering.mm). Declared
// here rather than included, because Unity's headers want its prefix header; weak so that a build
// which does not have it -- anything but a Unity player -- falls back to the system device instead
// of failing to link.
extern "C" id<MTLDevice> UnityGetMetalDevice(void) __attribute__((weak_import));

// The library's own fetch, so a video is opened by its place in the same list the photos use.
extern "C" PHAsset *CardboardXR_SpatialAssetAt(int index);

namespace
{
    enum LoadState
    {
        LoadStateIdle = 0,
        LoadStateLoading = 1,
        LoadStateReady = 2,
        LoadStateFailed = 3,
    };

    // How many frames' textures are held before one is let go. Unity's render thread reads a frame
    // after the script that handed it over has returned, so the texture it is reading has to outlive
    // the pull that replaced it; three slots leave two whole frames of slack.
    constexpr int k_Held = 3;

    AVPlayer *g_Player = nil;
    AVPlayerVideoOutput *g_Output API_AVAILABLE(ios(17.2)) = nil;
    id g_EndObserver = nil;
    CVMetalTextureCacheRef g_Cache = nullptr;

    // The textures still alive, this frame's at g_Slot. Holding the CVMetalTexture holds both the
    // Metal texture and the decoder's pixel buffer behind it.
    CVMetalTextureRef g_Held[2][k_Held] = {};
    int g_Slot = 0;
    int g_Width = 0;
    int g_Height = 0;
    bool g_Stereo = false;
    // The frame now in g_Held[.][g_Slot], so a pull that lands on the same one does no work.
    CMTime g_Shown = kCMTimeInvalid;

    std::atomic<int> g_State{LoadStateIdle};
    // Which open the player belongs to, so a video opened while another is still being fetched
    // doesn't start playing the older one.
    std::atomic<int> g_Request{0};
    NSString *g_Error = nil;

    void ReleaseTextures()
    {
        for (int eye = 0; eye < 2; eye++)
        {
            for (int slot = 0; slot < k_Held; slot++)
            {
                if (g_Held[eye][slot] != nullptr)
                    CFRelease(g_Held[eye][slot]);
                g_Held[eye][slot] = nullptr;
            }
        }
        g_Slot = 0;
        g_Width = g_Height = 0;
        g_Stereo = false;
        g_Shown = kCMTimeInvalid;
    }

    void Teardown() API_AVAILABLE(ios(17.2))
    {
        if (g_EndObserver != nil)
        {
            [NSNotificationCenter.defaultCenter removeObserver:g_EndObserver];
            g_EndObserver = nil;
        }
        [g_Player pause];
        g_Player.videoOutput = nil;
        [g_Player replaceCurrentItemWithPlayerItem:nil];
        g_Player = nil;
        g_Output = nil;

        ReleaseTextures();
        if (g_Cache != nullptr)
        {
            CFRelease(g_Cache);
            g_Cache = nullptr;
        }
    }

    void Fail(NSString *why) API_AVAILABLE(ios(17.2))
    {
        Teardown();
        g_Error = why;
        g_State = LoadStateFailed;
        NSLog(@"[Spatial] %@", why);
    }

    // The stereo views the decoder should hand back, in the order the player should try them: both
    // eyes first, then one, so a file holding a single view still plays rather than showing nothing.
    // Nil if the collections can't be made.
    NSArray *WantedViews() API_AVAILABLE(ios(17.2))
    {
        CMTagCollectionRef stereo = nullptr;
        CMTagCollectionRef mono = nullptr;
        if (CMTagCollectionCreateWithVideoOutputPreset(
                kCFAllocatorDefault, kCMTagCollectionVideoOutputPreset_Stereoscopic, &stereo) != noErr)
            return nil;
        if (CMTagCollectionCreateWithVideoOutputPreset(
                kCFAllocatorDefault, kCMTagCollectionVideoOutputPreset_Monoscopic, &mono) != noErr)
        {
            CFRelease(stereo);
            return nil;
        }
        NSArray *collections = @[(__bridge id)stereo, (__bridge id)mono];
        CFRelease(stereo);
        CFRelease(mono);
        return collections;
    }

    // Wraps one eye's pixels as a Metal texture in this frame's slot. The buffer is not copied: the
    // texture is a view of the decoder's own memory, which the CVMetalTexture keeps alive.
    bool Hold(CVPixelBufferRef buffer, int eye)
    {
        if (buffer == nullptr || g_Cache == nullptr)
            return false;
        const size_t width = CVPixelBufferGetWidth(buffer);
        const size_t height = CVPixelBufferGetHeight(buffer);
        if (width == 0 || height == 0)
            return false;

        CVMetalTextureRef texture = nullptr;
        // sRGB, so the GPU converts to linear as it samples: the project renders in linear space
        // and the decoder's BGRA holds sRGB-encoded values.
        const CVReturn made = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, g_Cache, buffer, nullptr,
            MTLPixelFormatBGRA8Unorm_sRGB, width, height, 0, &texture);
        if (made != kCVReturnSuccess || texture == nullptr)
            return false;

        // The slot being written holds the frame from k_Held pulls ago, which nothing is reading.
        if (g_Held[eye][g_Slot] != nullptr)
            CFRelease(g_Held[eye][g_Slot]);
        g_Held[eye][g_Slot] = texture;
        g_Width = (int)width;
        g_Height = (int)height;
        return true;
    }

    // Fetches the asset's original file and starts it playing, both eyes decoded. Returns the
    // request number, which is what C# gets back from the open.
    int Open(PHAsset *asset) API_AVAILABLE(ios(18.0))
    {
        const int request = g_Request.fetch_add(1) + 1;
        Teardown();
        g_Error = nil;
        g_State = LoadStateLoading;

        PHVideoRequestOptions *options = [PHVideoRequestOptions new];
        // The original, not the current version: the current one is rendered with the user's edits
        // applied, and that render is a single flat view. The cost is that a trimmed spatial video
        // plays in full.
        options.version = PHVideoRequestOptionsVersionOriginal;
        options.networkAccessAllowed = YES;

        [PHImageManager.defaultManager requestAVAssetForVideo:asset options:options
            resultHandler:^(AVAsset *video, AVAudioMix *audioMix, NSDictionary *info) {
                // Onto the main thread, where the player and its output are read every frame.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_Request.load() != request)
                        return;
                    if (video == nil)
                    {
                        Fail(@"Photos returned nothing for that spatial video");
                        return;
                    }

                    id<MTLDevice> device = UnityGetMetalDevice != nullptr
                        ? UnityGetMetalDevice() : MTLCreateSystemDefaultDevice();
                    if (device == nil ||
                        CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr,
                                                  &g_Cache) != kCVReturnSuccess)
                    {
                        Fail(@"No Metal device to decode the spatial video into");
                        return;
                    }

                    NSArray *views = WantedViews();
                    if (views == nil)
                    {
                        Fail(@"Couldn't ask the decoder for two stereo views");
                        return;
                    }
                    AVVideoOutputSpecification *specification =
                        [[AVVideoOutputSpecification alloc] initWithTagCollections:views];
                    // BGRA so each eye is one texture rather than a pair of luma and chroma planes,
                    // and Metal-compatible so it can be wrapped instead of copied.
                    specification.defaultOutputSettings = @{
                        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                    };
                    g_Output = [[AVPlayerVideoOutput alloc] initWithSpecification:specification];

                    // The output goes on before the item: AVPlayer chooses an item's data channels
                    // when the item is set, and with no output yet it would choose a single view.
                    g_Player = [AVPlayer new];
                    g_Player.videoOutput = g_Output;
                    // Looping, as the file player does, which needs the player not to stop at the end.
                    g_Player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
                    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:video];
                    if (audioMix != nil)
                        item.audioMix = audioMix;
                    [g_Player replaceCurrentItemWithPlayerItem:item];
                    g_EndObserver = [NSNotificationCenter.defaultCenter
                        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item
                        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                            [g_Player seekToTime:kCMTimeZero];
                            [g_Player play];
                        }];
                    [g_Player play];

                    g_State = LoadStateReady;
                    NSLog(@"[Spatial] Spatial video opened, %.1f s", CMTimeGetSeconds(video.duration));
                });
            }];
        return request;
    }

    // Takes the newest frame the player has for now, if it has one this pull hasn't already taken.
    void TakeFrame() API_AVAILABLE(ios(18.0))
    {
        if (g_Output == nil || g_State.load() != LoadStateReady)
            return;
        const CMTime host = CMClockGetTime(CMClockGetHostTimeClock());
        CMTime shown = kCMTimeInvalid;
        CMTaggedBufferGroupRef group = [g_Output copyTaggedBufferGroupForHostTime:host
                                                            presentationTimeStamp:&shown
                                                              activeConfiguration:nil];
        if (group == nullptr)
            return;

        // The same frame as last time, so what is already held still stands.
        const bool same = CMTIME_IS_VALID(g_Shown) && CMTIME_IS_VALID(shown) &&
                          CMTimeCompare(g_Shown, shown) == 0;
        if (!same)
        {
            CVPixelBufferRef left =
                CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagStereoLeftEye, nullptr);
            CVPixelBufferRef right =
                CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagStereoRightEye, nullptr);
            const bool pair = left != nullptr && right != nullptr;
            // One view: whatever the group does hold, shown to both eyes rather than nothing.
            if (!pair)
                left = right = CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, 0);

            const int was = g_Slot;
            g_Slot = (g_Slot + 1) % k_Held;
            if (Hold(left, 0) && Hold(right, 1))
            {
                g_Stereo = pair;
                g_Shown = shown;
            }
            else
            {
                // Go on showing the frame that worked rather than a half-replaced pair.
                g_Slot = was;
            }
        }
        CFRelease(group);
    }
}

// Starts loading one spatial video. Returns 0 if the item isn't a video this can open.
extern "C" int CardboardXR_SpatialOpenVideo(int index)
{
    PHAsset *asset = CardboardXR_SpatialAssetAt(index);
    if (asset == nil || asset.mediaType != PHAssetMediaTypeVideo)
        return 0;
    if (@available(iOS 18.0, *))
        return Open(asset);

    // Said rather than refused in silence, since the item is in the library and was pinched.
    g_Error = @"Spatial video needs iOS 18 or later";
    g_State = LoadStateFailed;
    return 0;
}

// 0 nothing asked for, 1 loading, 2 ready, 3 failed.
extern "C" int CardboardXR_SpatialVideoState() { return g_State.load(); }

extern "C" const char *CardboardXR_SpatialVideoError()
{
    return g_Error != nil ? g_Error.UTF8String : "";
}

// The two eyes of the frame to show now, as Metal textures Unity draws as external textures. Both
// eyes carry the same texture for a file that holds one view, and `stereo` then says so. Returns 0
// while there is no frame yet.
extern "C" int CardboardXR_SpatialVideoFrame(void **left, void **right, int *width, int *height, int *stereo)
{
    if (@available(iOS 18.0, *))
        TakeFrame();

    // Written before anything can return: an `out` on the other side is a pointer to a local the
    // caller never initialized, so leaving one alone hands back whatever was on its stack.
    if (left != nullptr)
        *left = nullptr;
    if (right != nullptr)
        *right = nullptr;
    if (width != nullptr)
        *width = 0;
    if (height != nullptr)
        *height = 0;
    if (stereo != nullptr)
        *stereo = 0;

    CVMetalTextureRef leftTexture = g_Held[0][g_Slot];
    CVMetalTextureRef rightTexture = g_Held[1][g_Slot];
    if (leftTexture == nullptr || rightTexture == nullptr)
        return 0;
    if (left != nullptr)
        *left = (__bridge void *)CVMetalTextureGetTexture(leftTexture);
    if (right != nullptr)
        *right = (__bridge void *)CVMetalTextureGetTexture(rightTexture);
    if (width != nullptr)
        *width = g_Width;
    if (height != nullptr)
        *height = g_Height;
    if (stereo != nullptr)
        *stereo = g_Stereo ? 1 : 0;
    return 1;
}

extern "C" void CardboardXR_SpatialVideoSetPlaying(int playing)
{
    if (playing != 0)
        [g_Player play];
    else
        [g_Player pause];
}

extern "C" int CardboardXR_SpatialVideoPlaying()
{
    // The rate rather than timeControlStatus: a player waiting to buffer is still meant to be
    // playing, and the controls should go on showing pause.
    return g_Player != nil && g_Player.rate != 0.0f ? 1 : 0;
}

extern "C" double CardboardXR_SpatialVideoTime()
{
    if (g_Player == nil)
        return 0.0;
    const double seconds = CMTimeGetSeconds(g_Player.currentTime);
    return isfinite(seconds) ? seconds : 0.0;
}

extern "C" double CardboardXR_SpatialVideoLength()
{
    AVPlayerItem *item = g_Player.currentItem;
    if (item == nil)
        return 0.0;
    const double seconds = CMTimeGetSeconds(item.duration);
    return isfinite(seconds) ? seconds : 0.0;
}

extern "C" void CardboardXR_SpatialVideoSeek(double seconds)
{
    if (g_Player == nil)
        return;
    // Exactly where asked rather than the nearest keyframe, because the seek bar is read back from
    // the position: landing seconds away from the click would make the bar jump under the thumb.
    [g_Player seekToTime:CMTimeMakeWithSeconds(seconds, 600)
         toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

extern "C" void CardboardXR_SpatialVideoClose()
{
    g_Request.fetch_add(1);
    // Nothing can have been opened on anything older, so there is nothing to tear down there.
    if (@available(iOS 17.2, *))
        Teardown();
    g_Error = nil;
    g_State = LoadStateIdle;
}
