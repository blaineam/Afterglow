using System;
using UnityEngine;

namespace CardboardXR.Stereo
{
    // The user's saved settings: what used to need a launch from the Mac, kept in PlayerPrefs under
    // the launch option's own name, so one name means one thing everywhere. A launch option still
    // overrides a saved setting for that run, which is what a launch option is for: comparing two
    // values without touching what the user chose.
    //
    // Int, not typed: every option here is a whole number already (a percentage, a rate, a count,
    // or a 0/1), and one shape keeps the settings screen a table rather than a type per row.
    public static class Settings
    {
        const string k_Prefix = "CardboardXR.Setting.";

        // Raised with the name of a setting that changed, for whatever applies it live.
        public static event Action<string> Changed;

        public static bool IsSaved(string name) => PlayerPrefs.HasKey(k_Prefix + name);

        // What the user saved, or the default: what the settings screen shows.
        public static int Saved(string name, int fallback) => PlayerPrefs.GetInt(k_Prefix + name, fallback);

        // What to use: a launch option for this run, else what the user saved, else the default.
        public static int Int(string name, int fallback) => LaunchOptions.GetInt(name, Saved(name, fallback));

        public static void Set(string name, int value)
        {
            if (IsSaved(name) && Saved(name, value) == value)
                return;
            PlayerPrefs.SetInt(k_Prefix + name, value);
            PlayerPrefs.Save();
            Debug.Log($"[Settings] {name} = {value}");
            Changed?.Invoke(name);
        }

        // Back to the default, which is whatever the code's own fallback is.
        public static void Clear(string name)
        {
            if (!IsSaved(name))
                return;
            PlayerPrefs.DeleteKey(k_Prefix + name);
            PlayerPrefs.Save();
            Debug.Log($"[Settings] {name} back to its default");
            Changed?.Invoke(name);
        }
    }
}
