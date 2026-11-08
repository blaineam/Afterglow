# Third-party notices

## Google Cardboard SDK

Parts of `app/Afterglow/Stereo/` are Swift ports of the Cardboard SDK
(https://github.com/googlevr/cardboard), licensed under the Apache License 2.0:

- `PolynomialRadialDistortion.swift` — from `sdk/polynomial_radial_distortion.cc`
- `LensDistortion.swift` — from `sdk/lens_distortion.cc` and `sdk/distortion_mesh.cc`
- `ViewerParams.swift` — field layout from `proto/cardboard_device.proto`

Changes from the original: translated from C++ to Swift, triangle strips replaced with a triangle list,
and an iteration cap added to the inverse distortion solver.

Copyright 2019 Google LLC. Licensed under the Apache License, Version 2.0:
http://www.apache.org/licenses/LICENSE-2.0

## CardboardXR

Afterglow began as a fork of brenpoly's CardboardXR (https://github.com/brenpoly/CardboardXR), under
the Apache License 2.0. The printed viewer in `Hardware/upstream-stretch/` and `Hardware/focus-brake/`
derives from brenpoly's Mobile VR viewer for modern smartphones, under CC BY-NC-SA 4.0.

## Song tempo data

The rhythm game's tempo lookup uses the free [audiometa.io](https://audiometa.io) music data API.

## Headset photos

The photos in `docs/photos/`, used by the headset timeline page, are from Wikimedia Commons. Each
keeps its own license (CC BY, CC BY-SA, CC0 or public domain), and the page credits its author and
license and links to its Commons page beside it.
