using System;
using System.Collections.Generic;
using Afterglow.Interaction;
using Afterglow.Stereo;
using Afterglow.UI;
using TMPro;
using UnityEngine;

namespace Afterglow.Demos
{
    // Keys you look at and pinch, for when there is no Bluetooth keyboard and nothing to say.
    //
    // It is the slowest of the three ways to type here, and it is the one that always works: no
    // pairing, no permission, no quiet room. So it is the floor the other two stand on rather
    // than the way typing is expected to go.
    //
    // The keys are ordinary M3 buttons, which means PinchRouter already presses whichever one the
    // gaze is on before the scene sees the pinch -- the same path the toolbar uses. Nothing here
    // handles input itself.
    public class WebKeyboard : MonoBehaviour
    {
        // A character to insert.
        public event Action<string> Typed;
        // "Backspace", "Clear" or "Enter".
        public event Action<string> Pressed;
        // The microphone button, which the session turns into dictation.
        public event Action Dictate;

        // In dp, which M3Canvas turns into a fixed angular size: 1 dp is about 1.74 mm at the
        // overlay distance, so ten keys at this pitch span the same width as the toolbar -- about
        // 47 degrees. Wider was tried at 76 and reaches 58, which is the whole of what the lenses
        // show and puts the outer keys where the distortion is worst. A key is 3.5 degrees across,
        // which a gaze can hold.
        const float k_Key = 58f;        // pitch between key centres
        const float k_KeyWidth = 52f;
        const float k_Wide = 84f;
        const float k_Row = 58f;
        const float k_Caption = 44f;

        static readonly string[] k_Letters = { "qwertyuiop", "asdfghjkl", "zxcvbnm" };
        // The last row is seven on both layers on purpose: the backspace key sits just past its
        // end, and an eighth character pushes the two into each other and off the panel.
        static readonly string[] k_Symbols = { "1234567890", "-/:;()$&@\"", ".,?!'+#" };

        RectTransform m_Canvas;
        TMP_Text m_Caption;
        readonly List<GameObject> m_Keys = new();
        bool m_Shifted;
        bool m_SymbolLayer;
        string m_CaptionText = "";

        public bool IsOpen => m_Canvas != null && m_Canvas.gameObject.activeSelf;

        // Where the panel sits, so the session can place it each frame with the rest.
        public RectTransform Panel => m_Canvas;

        public void Open()
        {
            if (m_Canvas == null)
                Build();
            m_Canvas.gameObject.SetActive(true);
        }

        public void Close()
        {
            if (m_Canvas != null)
                m_Canvas.gameObject.SetActive(false);
        }

        public void Toggle()
        {
            if (IsOpen)
                Close();
            else
                Open();
        }

        // What is being typed and where it is going, shown above the keys. In a viewer the field
        // on the page may be too small to read, so the keyboard repeats it.
        public void SetCaption(string text)
        {
            m_CaptionText = text ?? "";
            if (m_Caption != null)
                m_Caption.text = m_CaptionText;
        }

        void OnDestroy()
        {
            if (m_Canvas != null)
                Destroy(m_Canvas.gameObject);
        }

        void Build()
        {
            // Four rows of keys, a caption over them, and padding.
            const float width = 10f * k_Key + 48f;
            const float height = 4f * k_Row + k_Caption + 56f;
            m_Canvas = M3.Canvas("Web Keyboard", transform, new Vector2(width, height),
                M3Theme.k_OverlayDistance, M3Theme.SurfaceContainer, M3Theme.k_ShapePanel);
            m_Canvas.gameObject.AddComponent<GazeCanvas>();

            var top = height / 2f;
            m_Caption = M3.Text("Caption", m_Canvas, m_CaptionText, M3Theme.Type.BodyMedium,
                new Vector2(0f, top - 36f), new Vector2(width - 48f, k_Caption),
                M3Theme.OnSurfaceVariant);
            Layout();
        }

        // Rebuilt rather than relabelled when the layer or the case changes: a key's width
        // depends on its label, and swapping 30 labels in place leaves the pills the wrong size.
        void Layout()
        {
            foreach (var key in m_Keys)
                if (key != null)
                    Destroy(key);
            m_Keys.Clear();

            var rows = m_SymbolLayer ? k_Symbols : k_Letters;
            var height = m_Canvas.sizeDelta.y;
            var firstRow = height / 2f - k_Caption - 54f;

            for (var r = 0; r < rows.Length; r++)
            {
                var row = rows[r];
                var y = firstRow - r * k_Row;
                // Centred on the row, so the shorter rows sit under the longer ones.
                var left = -(row.Length - 1) / 2f;
                for (var i = 0; i < row.Length; i++)
                {
                    var character = m_SymbolLayer || !m_Shifted
                        ? row[i].ToString()
                        : row[i].ToString().ToUpperInvariant();
                    AddKey(character, new Vector2((left + i) * k_Key, y), k_KeyWidth,
                        () => Typed?.Invoke(character));
                }

                // The third row carries backspace past its end, and on the letter layer the case
                // key before its start. Not on the symbol layer: there is no upper case there, so
                // the key would be one that visibly does nothing, which is worse than no key.
                if (r != rows.Length - 1)
                    continue;
                var edge = (row.Length / 2f + 0.9f) * k_Key;
                if (!m_SymbolLayer)
                    AddKey(m_Shifted ? "ABC" : "abc", new Vector2(-edge, y), k_Wide,
                        () => { m_Shifted = !m_Shifted; Layout(); });
                AddKey("", new Vector2(edge, y), k_Wide,
                    () => Pressed?.Invoke("Backspace"), "backspace");
            }

            // The bottom row: the layer, the microphone, the space bar, and the one that commits.
            var bottom = firstRow - rows.Length * k_Row;
            AddKey(m_SymbolLayer ? "abc" : "?123", new Vector2(-4.1f * k_Key, bottom), k_Wide,
                () => { m_SymbolLayer = !m_SymbolLayer; Layout(); });
            AddKey("", new Vector2(-2.7f * k_Key, bottom), k_KeyWidth,
                () => Dictate?.Invoke(), "mic");
            AddKey("space", new Vector2(-0.2f * k_Key, bottom), 4f * k_Key,
                () => Typed?.Invoke(" "));
            AddKey("", new Vector2(2.6f * k_Key, bottom), k_KeyWidth,
                () => Pressed?.Invoke("Clear"), "delete");
            AddKey("Go", new Vector2(4.1f * k_Key, bottom), k_Wide,
                () => Pressed?.Invoke("Enter"));
        }

        void AddKey(string label, Vector2 position, float width, UnityEngine.Events.UnityAction action,
                    string icon = null)
        {
            // Icon-only keys are round buttons; the rest are pills as wide as they were asked to be.
            var button = string.IsNullOrEmpty(label) && !string.IsNullOrEmpty(icon)
                ? M3.IconButton(icon, m_Canvas, icon, M3Button.Variant.Tonal, position, action)
                : M3.Button(label, m_Canvas, label, M3Button.Variant.Tonal, position, action, icon, width);
            m_Keys.Add(button.gameObject);
        }
    }
}
