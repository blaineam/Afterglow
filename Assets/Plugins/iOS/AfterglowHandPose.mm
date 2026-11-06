// Hand pose from Apple's Vision framework, for HandTracker on iOS: VNDetectHumanHandPoseRequest
// finds up to two hands in a camera image and gives 21 joints each, with a confidence per joint
// and which hand it is, and it runs on the Neural Engine rather than the CPU. The app hands over
// its RGBA camera image (Afterglow_HandPoseSubmit), the request runs on a queue of its own, and
// the app polls for the result (Afterglow_HandPosePoll). One image at a time: a submit while the
// last is still running is refused, so the app never queues up work it can't use. Nothing here
// keeps or logs the image.
//
// The result is a flat float array, in the landmark order the app uses everywhere (MediaPipe's):
//   [0] hands found (0..2)
//   then per hand: chirality (0 unknown, 1 left, 2 right), the hand's own confidence,
//   and 21 x (x, y, confidence) with x and y in image pixels, y down.
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>
#include <string.h>

#define AFTERGLOW_HAND_JOINTS 21
#define AFTERGLOW_MAX_HANDS 2
#define AFTERGLOW_HAND_FLOATS (2 + AFTERGLOW_HAND_JOINTS * 3)
#define AFTERGLOW_RESULT_FLOATS (1 + AFTERGLOW_MAX_HANDS * AFTERGLOW_HAND_FLOATS)

static dispatch_queue_t g_Queue;
static VNDetectHumanHandPoseRequest *g_Request;
static NSArray<VNHumanHandPoseObservationJointName> *g_JointOrder;
static CVPixelBufferRef g_Buffer;
static int g_BufferWidth, g_BufferHeight;
static NSLock *g_Lock;
static BOOL g_Busy;
static int g_SubmitSequence;
static int g_ResultSequence;   // the sequence of the result waiting in g_Result, 0 for none
static float g_Result[AFTERGLOW_RESULT_FLOATS];
static double g_LastMs;        // how long the last request took, for the app's log

static void AfterglowHandPoseSetup(void)
{
    if (g_Queue != nil)
        return;
    g_Queue = dispatch_queue_create("com.wemiller.afterglow.handpose", DISPATCH_QUEUE_SERIAL);
    g_Lock = [NSLock new];
    g_Request = [VNDetectHumanHandPoseRequest new];
    g_Request.maximumHandCount = AFTERGLOW_MAX_HANDS;
    // MediaPipe's order: wrist, thumb CMC/MCP/IP/tip, then index, middle, ring and little, each
    // MCP/PIP/DIP/tip. Vision calls the thumb's second joint MP.
    g_JointOrder = @[
        VNHumanHandPoseObservationJointNameWrist,
        VNHumanHandPoseObservationJointNameThumbCMC, VNHumanHandPoseObservationJointNameThumbMP,
        VNHumanHandPoseObservationJointNameThumbIP, VNHumanHandPoseObservationJointNameThumbTip,
        VNHumanHandPoseObservationJointNameIndexMCP, VNHumanHandPoseObservationJointNameIndexPIP,
        VNHumanHandPoseObservationJointNameIndexDIP, VNHumanHandPoseObservationJointNameIndexTip,
        VNHumanHandPoseObservationJointNameMiddleMCP, VNHumanHandPoseObservationJointNameMiddlePIP,
        VNHumanHandPoseObservationJointNameMiddleDIP, VNHumanHandPoseObservationJointNameMiddleTip,
        VNHumanHandPoseObservationJointNameRingMCP, VNHumanHandPoseObservationJointNameRingPIP,
        VNHumanHandPoseObservationJointNameRingDIP, VNHumanHandPoseObservationJointNameRingTip,
        VNHumanHandPoseObservationJointNameLittleMCP, VNHumanHandPoseObservationJointNameLittlePIP,
        VNHumanHandPoseObservationJointNameLittleDIP, VNHumanHandPoseObservationJointNameLittleTip,
    ];
}

// A BGRA pixel buffer of the image's size, kept between images.
static BOOL AfterglowHandPoseBuffer(int width, int height)
{
    if (g_Buffer != NULL && g_BufferWidth == width && g_BufferHeight == height)
        return YES;
    if (g_Buffer != NULL)
        CVPixelBufferRelease(g_Buffer);
    g_Buffer = NULL;
    NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn made = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes, &g_Buffer);
    if (made != kCVReturnSuccess)
    {
        g_Buffer = NULL;
        return NO;
    }
    g_BufferWidth = width;
    g_BufferHeight = height;
    return YES;
}

static void AfterglowHandPoseRead(VNHumanHandPoseObservation *hand, float *out, int width, int height)
{
    NSError *error = nil;
    NSDictionary<VNHumanHandPoseObservationJointName, VNRecognizedPoint *> *points =
        [hand recognizedPointsForJointsGroupName:VNHumanHandPoseObservationJointsGroupNameAll error:&error];
    out[0] = hand.chirality == VNChiralityLeft ? 1.0f : hand.chirality == VNChiralityRight ? 2.0f : 0.0f;
    out[1] = hand.confidence;
    for (int i = 0; i < AFTERGLOW_HAND_JOINTS; i++)
    {
        VNRecognizedPoint *point = points != nil ? points[g_JointOrder[i]] : nil;
        float *joint = out + 2 + i * 3;
        if (point == nil)
        {
            joint[0] = joint[1] = joint[2] = 0.0f;
            continue;
        }
        // Vision's points are normalized with the origin at the bottom left; the app's images
        // have their first row at the top.
        joint[0] = (float)(point.location.x * width);
        joint[1] = (float)((1.0 - point.location.y) * height);
        joint[2] = point.confidence;
    }
}

// Takes an RGBA image (rows from the top, `stride` bytes per row) and starts the request on it.
// `orientation` is a CGImagePropertyOrientation (1 up ... 8), the way the image has to be turned
// to be upright. Returns the request's sequence number, or 0 if the last request is still
// running or the image couldn't be taken.
extern "C" int Afterglow_HandPoseSubmit(const unsigned char *rgba, int width, int height, int stride, int orientation)
{
    if (rgba == NULL || width < 8 || height < 8)
        return 0;
    AfterglowHandPoseSetup();
    [g_Lock lock];
    if (g_Busy)
    {
        [g_Lock unlock];
        return 0;
    }
    g_Busy = YES;
    int sequence = ++g_SubmitSequence;
    [g_Lock unlock];

    if (!AfterglowHandPoseBuffer(width, height))
    {
        [g_Lock lock]; g_Busy = NO; [g_Lock unlock];
        return 0;
    }
    CVPixelBufferLockBaseAddress(g_Buffer, 0);
    vImage_Buffer source = { (void *)rgba, (vImagePixelCount)height, (vImagePixelCount)width, (size_t)stride };
    vImage_Buffer target = { CVPixelBufferGetBaseAddress(g_Buffer), (vImagePixelCount)height, (vImagePixelCount)width,
                             CVPixelBufferGetBytesPerRow(g_Buffer) };
    // RGBA in, BGRA out: the channel order Vision takes without a conversion of its own.
    const uint8_t permute[4] = { 2, 1, 0, 3 };
    vImage_Error swizzled = vImagePermuteChannels_ARGB8888(&source, &target, permute, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(g_Buffer, 0);
    if (swizzled != kvImageNoError)
    {
        [g_Lock lock]; g_Busy = NO; [g_Lock unlock];
        return 0;
    }

    CGImagePropertyOrientation turn = (orientation >= 1 && orientation <= 8)
        ? (CGImagePropertyOrientation)orientation : kCGImagePropertyOrientationUp;
    CVPixelBufferRef buffer = g_Buffer;
    dispatch_async(g_Queue, ^{
        NSDate *started = [NSDate date];
        float result[AFTERGLOW_RESULT_FLOATS];
        memset(result, 0, sizeof(result));
        @autoreleasepool
        {
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer
                                                                                       orientation:turn
                                                                                           options:@{}];
            NSError *error = nil;
            if ([handler performRequests:@[g_Request] error:&error])
            {
                NSArray<VNHumanHandPoseObservation *> *hands = g_Request.results;
                int count = 0;
                for (VNHumanHandPoseObservation *hand in hands)
                {
                    if (count >= AFTERGLOW_MAX_HANDS)
                        break;
                    AfterglowHandPoseRead(hand, result + 1 + count * AFTERGLOW_HAND_FLOATS, width, height);
                    count++;
                }
                result[0] = (float)count;
            }
            else
            {
                result[0] = -1.0f;   // the request failed; the app logs it once
            }
        }
        [g_Lock lock];
        memcpy(g_Result, result, sizeof(result));
        g_ResultSequence = sequence;
        g_LastMs = -[started timeIntervalSinceNow] * 1000.0;
        g_Busy = NO;
        [g_Lock unlock];
    });
    return sequence;
}

// The latest result, if one is waiting: copies up to `capacity` floats and returns its sequence
// number, or 0 when there is nothing new. `ms` gets how long the request took.
extern "C" int Afterglow_HandPosePoll(float *out, int capacity, float *ms)
{
    if (out == NULL || g_Lock == nil)
        return 0;
    [g_Lock lock];
    int sequence = g_ResultSequence;
    if (sequence != 0)
    {
        int count = capacity < AFTERGLOW_RESULT_FLOATS ? capacity : AFTERGLOW_RESULT_FLOATS;
        memcpy(out, g_Result, (size_t)count * sizeof(float));
        if (ms != NULL)
            *ms = (float)g_LastMs;
        g_ResultSequence = 0;
    }
    [g_Lock unlock];
    return sequence;
}

extern "C" int Afterglow_HandPoseBusy(void)
{
    if (g_Lock == nil)
        return 0;
    [g_Lock lock];
    int busy = g_Busy ? 1 : 0;
    [g_Lock unlock];
    return busy;
}
