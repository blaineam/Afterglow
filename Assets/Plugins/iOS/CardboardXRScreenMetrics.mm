// The screen's physical size, which the lens distortion needs in meters. ScreenMetrics.cs is the
// C# side.
//
// iOS has no API for how big the screen is, only how many pixels it has, so the pixels have to be
// turned into millimeters by a table. Unity has such a table inside Screen.dpi, but it is keyed on
// the device model and so only knows the phones that existed when that Unity version shipped: on a
// newer one it can report a wrong density, or 0, and the stereo geometry is then wrong on every
// frame with nothing to say so.
//
// This table is keyed on the native pixel size instead, which is readable at runtime and needs no
// knowledge of the model. Pixel sizes are reused across generations (the iPhone 16 Pro Max and
// 18 Pro Max are both 2868 x 1320 at 460 ppi), so one row covers several phones, and an unknown
// phone falls back on its pixel count rather than on nothing: every iPhone since the X is between
// 458 and 476 ppi, so 460 is a close guess for anything that size, and a wrong guess of 460 is a
// small error where Screen.dpi's 0 or 160 is a ruinous one.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <sys/sysctl.h>

namespace
{
    struct ScreenRow
    {
        int longSide;
        int shortSide;
        float ppi;
    };

    // Native pixels (long side first) to pixels per inch, for the iPhones this app can run on.
    const ScreenRow k_Screens[] = {
        { 2868, 1320, 460.f },  // 6.9": 16/17/18 Pro Max
        { 2796, 1290, 460.f },  // 6.7": 14/15 Pro Max
        { 2622, 1206, 460.f },  // 6.3": 16/17/18 Pro
        { 2556, 1179, 460.f },  // 6.1": 14/15 Pro, 16/16e
        { 2532, 1170, 460.f },  // 6.1": 12/13/14
        { 2778, 1284, 458.f },  // 6.7": 12/13/14 Plus
        { 2688, 1242, 458.f },  // 6.5": XS Max, 11 Pro Max
        { 2436, 1125, 458.f },  // 5.8": X, XS, 11 Pro
        { 2340, 1080, 476.f },  // 5.4": 12/13 mini
        { 1792,  828, 326.f },  // 6.1": XR, 11
        { 1920, 1080, 401.f },  // 5.5": 6/7/8 Plus
        { 1334,  750, 326.f },  // 4.7": 6/7/8, SE 2/3
    };

    // Any iPhone from the X onward is 458-476 ppi; below that size it is one of the 326 ppi 4.7"
    // and 5.5" phones, which this app is far too heavy for but which shouldn't get a 460 ppi guess.
    const float k_ModernPpi = 460.f;
    const float k_OlderPpi = 326.f;
    const int k_ModernLongSide = 1800;

    NSString *MachineName()
    {
        size_t size = 0;
        if (sysctlbyname("hw.machine", nullptr, &size, nullptr, 0) != 0 || size == 0)
            return @"?";
        char *value = (char *)malloc(size);
        if (value == nullptr)
            return @"?";
        NSString *name = sysctlbyname("hw.machine", value, &size, nullptr, 0) == 0
            ? [NSString stringWithUTF8String:value] : @"?";
        free(value);
        return name;
    }
}

// Writes the landscape screen's width and height in millimeters, and a line saying where the
// numbers came from, into the buffers given. Returns 0 if the screen couldn't be measured, 1 if
// its pixel size was in the table, and 2 if the density was guessed from the pixel count.
extern "C" int CardboardXR_ScreenSizeMillimeters(float *width, float *height, char *source, int sourceLength)
{
    if (width == nullptr || height == nullptr)
        return 0;

    // nativeBounds is in pixels and always portrait, whichever way the device is held.
    const CGRect bounds = [UIScreen mainScreen].nativeBounds;
    const int longSide = (int)lround(MAX(bounds.size.width, bounds.size.height));
    const int shortSide = (int)lround(MIN(bounds.size.width, bounds.size.height));
    if (longSide <= 0 || shortSide <= 0)
        return 0;

    float ppi = 0.f;
    for (const ScreenRow &row : k_Screens)
    {
        if (row.longSide == longSide && row.shortSide == shortSide)
        {
            ppi = row.ppi;
            break;
        }
    }

    const bool known = ppi > 0.f;
    if (!known)
        ppi = longSide >= k_ModernLongSide ? k_ModernPpi : k_OlderPpi;

    // The viewer holds the phone in landscape, so the long side is the width.
    const float millimetersPerInch = 25.4f;
    *width = longSide / ppi * millimetersPerInch;
    *height = shortSide / ppi * millimetersPerInch;

    if (source != nullptr && sourceLength > 0)
    {
        NSString *text = [NSString stringWithFormat:@"iOS %@ %dx%d px at %.0f dpi (%@)",
                          MachineName(), longSide, shortSide, ppi,
                          known ? @"known screen" : @"density guessed from pixel count"];
        strlcpy(source, text.UTF8String, (size_t)sourceLength);
    }
    return known ? 1 : 2;
}
