using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace Afterglow.Stereo
{
    // Speaking instead of typing (Plugins/iOS/AfterglowDictation.mm).
    //
    // In a viewer you cannot see your hands, so aiming a gaze at one key at a time is the slowest
    // input the app has. This is the fastest, and the phone already does it well.
    //
    // On the phone only, and on the phone only in the other sense too: recognition is kept on
    // device, so what is said into the browser does not leave the hardware. Where a locale cannot
    // be recognised without Apple's servers this reports Unavailable instead of quietly
    // uploading the audio.
    public static class Dictation
    {
        // Kept in step with DictationState in the plugin.
        public enum State
        {
            Idle = 0,
            Asking = 1,
            Listening = 2,
            Denied = 3,
            Unavailable = 4,
            Failed = 5,
        }

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_DictationAvailable() != 0;
#else
            false;
#endif

        public static State Current =>
#if UNITY_IOS && !UNITY_EDITOR
            (State)Afterglow_DictationState();
#else
            State.Unavailable;
#endif

        public static bool Listening => Current == State.Listening;

        public static void Start()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_DictationStart();
#else
            Debug.Log("[Speech] Dictation is iOS only.");
#endif
        }

        public static void Stop()
        {
#if UNITY_IOS && !UNITY_EDITOR
            Afterglow_DictationStop();
#endif
        }

        // True once per phrase, cleared as it is read, so a caller commits the text exactly once.
        public static bool TakeFinished()
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_DictationTakeFinished() != 0;
#else
            return false;
#endif
        }

        // What has been heard so far, which grows as the phrase is spoken.
        public static string Text
        {
            get
            {
#if UNITY_IOS && !UNITY_EDITOR
                var needed = Afterglow_DictationCopyText(null, 0);
                if (needed <= 0)
                    return string.Empty;
                var buffer = new byte[needed + 1];
                Afterglow_DictationCopyText(buffer, buffer.Length);
                return Encoding.UTF8.GetString(buffer, 0, needed);
#else
                return string.Empty;
#endif
            }
        }

        // What to tell the user, which for everything except Listening is the whole of what the
        // feature can say for itself.
        public static string Describe(State state) => state switch
        {
            State.Idle => "Hold to speak",
            State.Asking => "Waiting for permission",
            State.Listening => "Listening",
            State.Denied => "Allow the microphone and speech recognition in Settings",
            State.Unavailable => "Dictation needs on-device speech, which this language lacks",
            _ => "Dictation didn't start",
        };

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_DictationAvailable();
        [DllImport("__Internal")] static extern void Afterglow_DictationStart();
        [DllImport("__Internal")] static extern void Afterglow_DictationStop();
        [DllImport("__Internal")] static extern int Afterglow_DictationState();
        [DllImport("__Internal")] static extern int Afterglow_DictationTakeFinished();
        [DllImport("__Internal")] static extern int Afterglow_DictationCopyText(byte[] buffer, int capacity);
#endif
    }
}
