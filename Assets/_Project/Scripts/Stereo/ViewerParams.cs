using System;

namespace CardboardXR.Stereo
{
    // Physical description of a Cardboard-style viewer, mirroring the Cardboard SDK's DeviceParams
    // protobuf (proto/cardboard_device.proto). Lengths are in meters, angles in degrees.
    [Serializable]
    public class ViewerParams
    {
        public enum VerticalAlignment
        {
            Bottom = 0, // phone rests against a fixed bottom tray
            Center = 1, // screen is centered on the lenses
            Top = 2,    // phone rests against a fixed top tray
        }

        public enum ButtonType
        {
            None = 0,
            Magnet = 1,
            Touch = 2,
            IndirectTouch = 3,
        }

        public string vendor = "";
        public string model = "";
        public float screenToLensDistance;
        public float interLensDistance;
        // Left eye's view extent (left, right, bottom, top) from the optical axis. The right eye
        // mirrors left and right.
        public float[] leftEyeFieldOfViewAngles = new float[4];
        public VerticalAlignment verticalAlignment = VerticalAlignment.Bottom;
        public float trayToLensDistance;
        // K1, K2, ... of p' = p (1 + K1 r^2 + K2 r^4 + ...), r in tan-angle units.
        public float[] distortionCoefficients = Array.Empty<float>();
        public ButtonType primaryButton = ButtonType.Magnet;

        // The original 2014 Cardboard. The Cardboard SDK falls back to these when no viewer QR code
        // has been scanned; values decoded from sdk/qrcode/cardboard_v1/cardboard_v1.cc.
        public static ViewerParams CardboardV1 => new()
        {
            vendor = "Google, Inc.",
            model = "Cardboard v1",
            screenToLensDistance = 0.042f,
            interLensDistance = 0.06f,
            leftEyeFieldOfViewAngles = new[] { 40f, 40f, 40f, 40f },
            verticalAlignment = VerticalAlignment.Bottom,
            trayToLensDistance = 0.035f,
            distortionCoefficients = new[] { 0.441f, 0.156f },
            primaryButton = ButtonType.Magnet,
        };

        // The 2015 Google Cardboard, whose lenses the printed viewers in this project's hardware
        // folder use. Values from a real viewer's QR code, decoded in ViewerParamsCodecTests; its
        // own code is at goo.gl/KS2FEm. Scanning that code gives exactly these, so this profile is
        // only the default for a build that hasn't been shown one.
        public static ViewerParams CardboardV2 => new()
        {
            vendor = "Google",
            model = "Cardboard",
            screenToLensDistance = 0.0393f,
            interLensDistance = 0.0639f,
            leftEyeFieldOfViewAngles = new[] { 60f, 60f, 60f, 60f },
            verticalAlignment = VerticalAlignment.Bottom,
            trayToLensDistance = 0.035f,
            distortionCoefficients = new[] { 0.3358f, 0.5535f },
            primaryButton = ButtonType.IndirectTouch,
        };

        // The printed viewer in this project's Hardware folder. Cardboard v2's lenses and spacing,
        // but with them centred on the screen rather than above a bottom tray: Cardboard's bottom
        // alignment puts the optical axis 32 mm up a 73 mm screen, costing vertical view below
        // (about 50 degrees against the lens's 60), where centred reaches about 58 both ways.
        //   No button, either: a Cardboard viewer needs one because its shell covers the screen,
        // and this app's input is gaze plus a pinch in front of the rear camera, which the open
        // back leaves clear.
        public static ViewerParams CardboardXRViewer => new()
        {
            vendor = "CardboardXR",
            model = "CardboardXR Viewer",
            screenToLensDistance = 0.0393f,
            interLensDistance = 0.0639f,
            leftEyeFieldOfViewAngles = new[] { 60f, 60f, 60f, 60f },
            verticalAlignment = VerticalAlignment.Center,
            trayToLensDistance = 0.035f,
            distortionCoefficients = new[] { 0.3358f, 0.5535f },
            primaryButton = ButtonType.None,
        };

        public ViewerParams Clone() => new()
        {
            vendor = vendor,
            model = model,
            screenToLensDistance = screenToLensDistance,
            interLensDistance = interLensDistance,
            leftEyeFieldOfViewAngles = (float[])leftEyeFieldOfViewAngles.Clone(),
            verticalAlignment = verticalAlignment,
            trayToLensDistance = trayToLensDistance,
            distortionCoefficients = (float[])distortionCoefficients.Clone(),
            primaryButton = primaryButton,
        };
    }
}
