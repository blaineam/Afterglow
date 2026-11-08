#!/bin/zsh
# Xcode Cloud, after the clone. The project is committed, but generating it keeps it true to
# project.yml. Exiting non-zero is the only way to end a run early.
set -euo pipefail
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/app"
xcodegen generate
