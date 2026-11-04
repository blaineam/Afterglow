using System;
using UnityEngine;
using UnityEngine.InputSystem;

namespace CardboardXR.Hands
{
    // A Bluetooth keyboard, which is the fastest way to type here by a wide margin.
    //
    // It reaches the page the long way round, as text rather than as keystrokes: the web view is
    // behind a veil that takes no interaction, so it is never the first responder and iOS never
    // delivers a key to it. Unity gets them instead, and the browser sends them on. That also
    // means the same path serves the on-screen keys and dictation, and the page cannot tell which
    // of the three typed into it.
    //
    // onTextInput rather than reading key states: it is what resolves a layout, a modifier and a
    // dead key into the character the user meant, which is not something worth reimplementing.
    // The keys that produce no character are read separately below.
    public static class KeyboardInput
    {
        // A character that was typed.
        public static event Action<string> Typed;
        // "Backspace", "Enter" or "Escape".
        public static event Action<string> Pressed;

        static Keyboard s_Bound;

        // Whether a keyboard is connected at all, for the UI to say so.
        public static bool Present => Keyboard.current != null;

        // Called every frame by whatever is accepting typing. Binds as a keyboard appears and
        // lets go as it goes, so one paired in the middle of a session starts working without a
        // restart -- which is how it will actually be paired, with the phone already in a viewer.
        public static void Poll()
        {
            var keyboard = Keyboard.current;
            if (!ReferenceEquals(keyboard, s_Bound))
            {
                if (s_Bound != null)
                {
                    s_Bound.onTextInput -= OnCharacter;
                    Debug.Log("[Keys] Keyboard gone");
                }
                s_Bound = keyboard;
                if (s_Bound != null)
                {
                    s_Bound.onTextInput += OnCharacter;
                    Debug.Log($"[Keys] Keyboard {s_Bound.name} connected");
                }
            }
            if (s_Bound == null)
                return;

            if (s_Bound.backspaceKey.wasPressedThisFrame)
                Pressed?.Invoke("Backspace");
            if (s_Bound.enterKey.wasPressedThisFrame || s_Bound.numpadEnterKey.wasPressedThisFrame)
                Pressed?.Invoke("Enter");
            if (s_Bound.escapeKey.wasPressedThisFrame)
                Pressed?.Invoke("Escape");
        }

        // Stops listening, so a handler that has gone away is not held alive by a static event.
        public static void Release()
        {
            if (s_Bound == null)
                return;
            s_Bound.onTextInput -= OnCharacter;
            s_Bound = null;
        }

        static void OnCharacter(char character)
        {
            // onTextInput reports the control characters too, and backspace and return are
            // already read as keys above -- without this they would be typed as characters as
            // well, so every backspace would also insert one.
            if (character < ' ' || character == (char)127)
                return;
            Typed?.Invoke(character.ToString());
        }
    }
}
