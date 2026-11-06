using Afterglow.UI;
using UnityEngine;

namespace Afterglow.Stereo
{
    // The "uiScale" setting (or launch option): how much bigger than Android XR's sizes the Material
    // UI is drawn, in percent (default M3Theme.k_DefaultCardboardScale), for tuning legibility
    // through a viewer. Set before the first scene loads, so every M3Canvas wakes with it, which is
    // also why a change from the settings screen waits for the next launch.
    static class UiScaleOption
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Apply()
        {
            var percent = Settings.Int("uiScale", 0);
            if (percent <= 0)
                return;
            M3Theme.CardboardScale = percent / 100f;
            Debug.Log($"[Stereo] UI scale {M3Theme.CardboardScale:F2} times Android XR's sizes");
        }
    }
}
