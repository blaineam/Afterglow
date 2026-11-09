import { homedir } from 'node:os';

// QA gates for Afterglow XR — resolved by: node ../_shared/soren/soren.mjs run Afterglow
// Build products live under ~/Library, off iCloud, as in Tools/native_build_and_run.sh.
const dd = (suite) => `${homedir()}/Library/Developer/Afterglow/soren-${suite}`;

export default {
  name: 'Afterglow XR',
  suites: {
    unit: {
      type: 'xcodebuild-test',
      project: 'Afterglow.xcodeproj', scheme: 'Afterglow', cwd: 'app',
      destination: 'platform=iOS Simulator,name=iPhone 18 Pro Max',
      derivedDataPath: dd('unit'),
      description: 'Game logic, the lock\'s spoken digits, speech and watch callbacks off the main actor',
      tags: ['regression'],
    },
    l10n: {
      type: 'cmd', cmd: 'python3',
      args: ['-I', 'Tools/check_l10n.py'],
      description: 'Catalogs complete in all 8 languages, specifiers in order, emoji, tags and {fps} kept, '
        + 'no interface string left out of a String(localized:)',
      tags: ['regression'],
    },
    languages: {
      type: 'cmd', cmd: 'zsh',
      args: ['Tools/test_languages.sh'],
      description: 'The app launches and runs in each of the nine languages on the Simulator, from a built '
        + 'bundle whose .lproj folders hold the phone, watch and permission strings',
      tags: ['regression'],
    },
    'watch-link': {
      type: 'cmd', cmd: 'zsh',
      args: ['Tools/test_watch_link.sh'],
      description: 'A watch Select and crown scroll reach the phone\'s frame loop over paired Simulators',
      tags: ['regression'],
    },
  },
  release: { requireGreen: ['unit', 'l10n', 'languages', 'watch-link'] },
};
