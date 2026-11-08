using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Serialization;

namespace Afterglow.Demos
{
    // The apps the home screen offers, each a scene of its own: the games and the room in the Play
    // section, and the media player in Media (the home screen's Media and Files tiles both open the
    // first Media entry). Entries are in the order their section shows them, and the "demo" launch
    // option picks one by its index here. The build includes each entry's scene after Core and the
    // Home scene.
    [CreateAssetMenu(menuName = "Afterglow/Demo Catalog")]
    public class DemoCatalog : ScriptableObject
    {
        // Which part of the home screen an entry belongs to.
        public enum Section
        {
            Play,
            Media,
        }

        [Serializable]
        public class Entry
        {
            [Tooltip("Short and stable, for logs.")]
            public string Id;
            public string Title;
            [TextArea] public string Description;
            [Tooltip("One line, shown on the home screen while the app is looked at.")]
            public string Tagline;
            [Tooltip("The home screen icon: a Material icon name (see M3Icons).")]
            public string Icon = "apps";
            [Tooltip("The home screen icon's tile color.")]
            public Color Tint = new(0.29f, 0.36f, 0.54f);
            [Tooltip("The scene's path, such as Assets/_Project/Demos/Video/Video.unity.")]
            public string ScenePath;
            public Section Section;
            public DemoRequirements Requirements;
        }

        [Tooltip("The Home scene's path: what the app starts in and comes back to.")]
        [FormerlySerializedAs("m_LobbyScenePath")]
        [SerializeField] string m_HomeScenePath = "Assets/_Project/Demos/Home/Home.unity";
        [Tooltip("What Home switches on when the app starts: 6DoF and passthrough, so the room is seen through the " +
                 "camera from the first moment and apps start with tracking running. (No room scan: an app that needs " +
                 "surfaces scans when it opens.)")]
        [FormerlySerializedAs("m_LobbyRequirements")]
        [SerializeField] DemoRequirements m_HomeRequirements = new() { SixDof = Need.On, Passthrough = Need.On, Hands = Need.On };
        [SerializeField] List<Entry> m_Demos = new();

        public string HomeScenePath => m_HomeScenePath;
        public DemoRequirements HomeRequirements => m_HomeRequirements;
        public IReadOnlyList<Entry> Demos => m_Demos;

        public bool TryGet(int index, out Entry entry)
        {
            entry = index >= 0 && index < m_Demos.Count ? m_Demos[index] : null;
            return entry != null;
        }

        public int IndexOf(string id) => m_Demos.FindIndex(entry => entry.Id == id);

        // The entries in a section, in catalog order.
        public List<Entry> InSection(Section section) => InSection(m_Demos, section);

        public static List<Entry> InSection(IReadOnlyList<Entry> entries, Section section)
        {
            var found = new List<Entry>();
            foreach (var entry in entries)
            {
                if (entry.Section == section)
                    found.Add(entry);
            }
            return found;
        }
    }
}
