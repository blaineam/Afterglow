using System.Collections.Generic;
using UnityEngine;

namespace Afterglow.Stereo
{
    // A virtual surrounding, such as a room, that passthrough hides so the camera image shows
    // instead. It can be in any scene, including a demo loaded after passthrough came on, which is
    // why PassthroughController finds these rather than holding a list. Goes on the environment's
    // root, which must be active when its scene loads.
    public class VirtualEnvironment : MonoBehaviour
    {
        static readonly List<VirtualEnvironment> s_All = new();
        static bool s_Hidden;
        static bool s_Replaced;

        // A replacement for the built-in surroundings (a 360 photo of the user's): shown instead
        // of them while one is chosen, hidden with them by passthrough.
        public bool IsReplacement;

        // Awake and OnDestroy rather than OnEnable and OnDisable, since hiding deactivates it.
        void Awake()
        {
            s_All.Add(this);
            Refresh(this);
        }

        void OnDestroy() => s_All.Remove(this);

        public static void SetAllHidden(bool hidden)
        {
            s_Hidden = hidden;
            foreach (var environment in s_All)
                Refresh(environment);
        }

        // Whether a replacement stands in for the built-in surroundings.
        public static void SetReplaced(bool replaced)
        {
            s_Replaced = replaced;
            foreach (var environment in s_All)
                Refresh(environment);
        }

        // Pure: whether an environment shows, given what's hiding or replacing it.
        public static bool Shows(bool isReplacement, bool hidden, bool replaced) =>
            !hidden && isReplacement == replaced;

        static void Refresh(VirtualEnvironment environment) =>
            environment.gameObject.SetActive(Shows(environment.IsReplacement, s_Hidden, s_Replaced));
    }
}
