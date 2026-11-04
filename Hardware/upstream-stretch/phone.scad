// The iPhone 18 Pro Max's own outline, shared by door.scad and locators.scad.
//
// The corner is a continuous-curvature curve, not an arc, so no single radius matches it. It is
// carried as points read off Apple's dimensional drawing (see README.md for the method) for the
// top-left corner in the phone's own centred coordinates; the other three are mirrors.
//
// Everything phone-shaped in this folder comes from here: the locators' inner faces, the door's
// camera opening and the door's retaining collar. That matters more than it sounds. While the
// opening was a plain rounded rectangle it could not agree with the phone at the corners, and the
// disagreement was what cost the door its camera end.

phone_x = 77.98;
phone_y = 163.43;

k_corner = [
    [-19.563,  81.712],
    [-21.235,  81.712],
    [-22.583,  81.710],
    [-23.054,  81.706],
    [-23.741,  81.702],
    [-24.380,  81.691],
    [-24.989,  81.675],
    [-25.509,  81.654],
    [-26.030,  81.626],
    [-26.540,  81.588],
    [-27.047,  81.538],
    [-27.551,  81.477],
    [-28.054,  81.404],
    [-28.482,  81.329],
    [-28.905,  81.243],
    [-29.327,  81.145],
    [-29.745,  81.037],
    [-30.159,  80.915],
    [-30.570,  80.779],
    [-30.974,  80.633],
    [-31.374,  80.470],
    [-31.768,  80.296],
    [-32.157,  80.108],
    [-32.535,  79.906],
    [-32.908,  79.692],
    [-33.273,  79.464],
    [-33.627,  79.223],
    [-34.311,  78.704],
    [-34.958,  78.136],
    [-35.561,  77.523],
    [-36.116,  76.868],
    [-36.625,  76.173],
    [-36.859,  75.811],
    [-37.081,  75.442],
    [-37.289,  75.065],
    [-37.484,  74.681],
    [-37.665,  74.290],
    [-37.833,  73.893],
    [-37.988,  73.490],
    [-38.129,  73.083],
    [-38.272,  72.620],
    [-38.399,  72.154],
    [-38.509,  71.683],
    [-38.607,  71.209],
    [-38.689,  70.736],
    [-38.758,  70.257],
    [-38.817,  69.779],
    [-38.862,  69.299],
    [-38.909,  68.693],
    [-38.940,  68.078],
    [-38.963,  67.447],
    [-38.977,  66.787],
    [-38.983,  66.283],
];

// The phone's outline, grown (or, with a negative argument, shrunk) by `extra`. Four mirrored
// copies of the one corner, walked in order so the straight edges between them close the loop.
module phone_plan(extra = 0) {
    n = len(k_corner);
    offset(r = extra) polygon(concat(
        k_corner,
        [for (i = [n - 1 : -1 : 0]) [ k_corner[i][0], -k_corner[i][1]]],
        [for (i = [0 : n - 1])      [-k_corner[i][0], -k_corner[i][1]]],
        [for (i = [n - 1 : -1 : 0]) [-k_corner[i][0],  k_corner[i][1]]]
    ));
}
