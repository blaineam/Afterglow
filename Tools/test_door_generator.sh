#!/bin/zsh
# Tests the door generator as the site serves it: a clean checkout of the site's main branch, every preset door in every
# MagSafe mode, against the stretched shell's mesh. The meshes are derivatives of a CC BY-NC-SA model, so they stay out of
# this repository: generate them once with Hardware/upstream-stretch/ into the folder below.
#   openscad --backend manifold -D 'SRCDIR="/path/to/download"' -o ~/Library/Developer/Afterglow/door-check/shell.stl shell.scad
#   openscad --backend manifold -D 'SRCDIR="/path/to/download"' -o ~/Library/Developer/Afterglow/door-check/door18pm.stl door.scad
set -u
SITE=${AFTERGLOW_SITE_REPO:-$HOME/Documents/scripts/blaineam.github.io}
MESH=${AFTERGLOW_DOOR_MESHES:-$HOME/Library/Developer/Afterglow/door-check}
TREE=$HOME/Worktrees/afterglow-door-check

[ -f $MESH/shell.stl ] || { echo "FAIL: no shell mesh in $MESH (see the top of this script)" >&2; exit 1; }
[ -f $MESH/door18pm.stl ] || { echo "FAIL: no printed-door mesh in $MESH (see the top of this script)" >&2; exit 1; }
git -C $SITE fetch -q origin || { echo "FAIL: could not fetch the site repo" >&2; exit 1; }
git -C $SITE worktree remove --force $TREE 2>/dev/null
git -C $SITE worktree add -q --detach $TREE origin/main || { echo "FAIL: could not check out the site" >&2; exit 1; }
trap 'git -C $SITE worktree remove --force $TREE 2>/dev/null' EXIT
node $TREE/scripts/check-door-generator.mjs --shell $MESH/shell.stl --reference $MESH/door18pm.stl
