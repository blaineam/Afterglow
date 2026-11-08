// What camera formats ARKit will actually give a world-tracking session on this phone.
//
// The hands leave the frame constantly -- the main camera sees about 68 degrees across and 42 up
// and down, and KNOWN_ISSUES records a hand leaving in four of eight drags -- so the ultra-wide
// lens would be worth a great deal. Apple documents choosing it for *face* tracking, by looking
// through supportedVideoFormats for one whose captureDeviceType is builtInUltraWideCamera; whether
// world tracking offers the same is not documented either way.
//
// Rather than argue from the documentation, this asks the device. AR Foundation's own
// configuration list does not carry captureDeviceType, so it cannot answer this.

#import <Foundation/Foundation.h>
#import <ARKit/ARKit.h>

// Writes a line per supported format into `out`. Returns how many there were.
extern "C" int Afterglow_VideoFormats(char *out, int length)
{
    NSMutableString *text = [NSMutableString string];
    int count = 0;

    if (@available(iOS 11.3, *))
    {
        NSArray<ARVideoFormat *> *formats = ARWorldTrackingConfiguration.supportedVideoFormats;
        for (ARVideoFormat *format in formats)
        {
            NSString *device = @"?";
            if (@available(iOS 14.5, *))
                device = format.captureDeviceType ?: @"?";
            NSString *position = @"?";
            if (@available(iOS 14.5, *))
                position = format.captureDevicePosition == AVCaptureDevicePositionFront ? @"front" : @"back";
            [text appendFormat:@"%.0fx%.0f @%ldfps %@ %@\n",
                format.imageResolution.width, format.imageResolution.height,
                (long)format.framesPerSecond, device, position];
            count++;
        }
    }

    if (out != nullptr && length > 0)
        strlcpy(out, text.UTF8String, (size_t)length);
    return count;
}
