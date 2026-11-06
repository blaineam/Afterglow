using System.Collections.Generic;

namespace Afterglow.UI
{
    // The Material Icons (Round) the app uses, by name, with their codepoints from the font's
    // codepoints file. The icon font asset is made with exactly these glyphs (MaterialAssets).
    public static class M3Icons
    {
        public static readonly IReadOnlyDictionary<string, int> Codepoints = new Dictionary<string, int>
        {
            ["home"] = 0xe88a,
            ["my_location"] = 0xe55c,
            ["view_in_ar"] = 0xe9fe,
            ["visibility"] = 0xe8f4,
            ["radar"] = 0xf04e,
            ["pinch"] = 0xeb38,
            ["qr_code_scanner"] = 0xf206,
            ["smartphone"] = 0xe32c,
            ["view_agenda"] = 0xe8e9,
            ["replay_10"] = 0xe059,
            ["forward_10"] = 0xe056,
            ["play_arrow"] = 0xe037,
            ["pause"] = 0xe034,
            ["skip_next"] = 0xe044,
            ["movie"] = 0xe02c,
            ["cloud_download"] = 0xe2c0,
            ["undo"] = 0xe166,
            ["delete"] = 0xe872,
            ["brush"] = 0xe3ae,
            ["close"] = 0xe5cd,
            ["refresh"] = 0xe5d5,
            ["door_front"] = 0xeffd,
            ["video_library"] = 0xe04a,
            ["aspect_ratio"] = 0xe85b,
            ["check"] = 0xe5ca,
            ["replay"] = 0xe042,
            ["360"] = 0xe577,
            ["touch_app"] = 0xe913,
            ["auto_awesome"] = 0xe65f,
            ["palette"] = 0xe40a,
            ["edit"] = 0xe3c9,
            ["circle"] = 0xef4a,
            ["line_weight"] = 0xe91a,
            ["emoji_events"] = 0xea23,
            ["stop"] = 0xe047,
            ["timer"] = 0xe425,
            ["settings"] = 0xe8b8,
            ["chevron_left"] = 0xe5cb,
            ["chevron_right"] = 0xe5cc,
            // Typing into the browser: the on-screen keys, and the two other ways in.
            ["backspace"] = 0xe14a,
            ["keyboard"] = 0xe312,
            ["keyboard_capslock"] = 0xe318,
            ["keyboard_hide"] = 0xe31a,
            ["mic"] = 0xe029,
            ["mic_off"] = 0xe02b,
            ["search"] = 0xe8b6,
            ["open_with"] = 0xe89f,
            ["restart_alt"] = 0xf053,
            ["flag"] = 0xe153,
            ["front_hand"] = 0xe769,
            ["apps"] = 0xe5c3,
            ["bolt"] = 0xea0b,
            // The settings panel's Settings and Browser items, and the settings screen's header and
            // its minus and plus buttons: all four drew as nothing until they were listed here.
            ["tune"] = 0xe429,
            ["public"] = 0xe80b,
            ["remove"] = 0xe15b,
            ["add"] = 0xe145,
            // The home screen: its sections, the Play page's back arrow, and the Room.
            ["photo_library"] = 0xe413,
            ["star"] = 0xe838,
            ["star_border"] = 0xe83a,
            ["folder"] = 0xe2c7,
            ["sports_esports"] = 0xea28,
            ["arrow_back"] = 0xe5c4,
            ["grid_view"] = 0xe9b0,
            // The media browser's tiles.
            ["panorama"] = 0xe40b,
            ["photo"] = 0xe410,
        };

        // The icon's character, for a TMP text set in the icon font; empty for an unknown name.
        public static string Glyph(string name) =>
            name != null && Codepoints.TryGetValue(name, out var codepoint) ? char.ConvertFromUtf32(codepoint) : "";

        // Every icon's character, for building the font asset.
        public static string AllGlyphs()
        {
            var text = new System.Text.StringBuilder();
            foreach (var codepoint in Codepoints.Values)
                text.Append(char.ConvertFromUtf32(codepoint));
            return text.ToString();
        }
    }
}
