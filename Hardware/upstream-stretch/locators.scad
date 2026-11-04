// TPU corner locators for the iPhone 18 Pro Max: the soft parts that take up the play between
// the phone and the shell's bay. Upstream ships four per phone and they are, with the door's
// camera opening, the whole of what makes a door phone-specific.
//
// These are a remake. The first version built the locators from scratch out of bay-minus-phone
// arithmetic -- a plain corner block with a square inner corner -- and they would not go into the
// door's pockets at all, because nothing in them referred to a pocket. The pockets are real
// features of the door plate (about 14.57 x 22.26 each, in its corners), and the only thing that
// reliably fits them is the shape upstream already made to fit them.
//
// So this does not model a locator. It takes upstream's own locator and does two things:
//
//   1. stretches it on exactly the same planes and by exactly the same amounts as the shell, the
//      carriage and the door (x = +-26 by 3.5, y = +-55 by 6), so the part of it that meets the
//      door's pocket travels with the pocket;
//   2. cuts the phone out of it. The inner face is then the iPhone 18 Pro Max's own corner,
//      carried as the profile Apple draws rather than as a radius, because that corner is a
//      continuous-curvature curve and no single radius matches it.
//
// Step 2 is also what takes up the change in play, with no arithmetic of its own. The phone grew
// 16.83 mm along where the bay grew 12.00, so the end gap closed from 7.58 mm to 2.75; cutting the
// real phone out of the stretched locator leaves exactly the material that gap has room for.
//
// `squeeze` is the one number that is a choice: the inner face is held that far inside the phone's
// outline, so the locator is compressed when the phone goes in and damps it instead of letting it
// rattle. Upstream's iPhone 15 Pro locator stands 1.81 mm proud of the phone corner into a 1.20 mm
// gap, which is 0.61 mm of the same thing.
//
//   openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' \
//            -D 'part="camera-top"' -o locator-camera-top.stl locators.scad
//
// Print in TPU. See README.md for why they are not printed in one piece with the door.

SRCDIR = "..";
part = "camera-top";          // camera-top, camera-bottom, usb-top, usb-bottom

// Which of upstream's four this one is remade from. They are not interchangeable: the camera-end
// pair differ from the USB-end pair, and the door's camera opening eats into one of them.
corner_file =
    part == "camera-top"    ? "top - camera-end" :
    part == "camera-bottom" ? "bottom - camera-end" :
    part == "usb-top"       ? "top - USB-end" :
                              "bottom - USB-end";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/TPU locator - ", corner_file, " corner.stl");

// The shell's cut planes and inserts, exactly as door.scad and shell.scad use them.
yc = 55; dy = 6;
xc = 26; dx = 3.5;
big = 400;

// Apple's figures for the phone (see README).
phone_x = 77.98;
phone_y = 163.43;
squeeze = 0.6;                // how far inside the phone's outline the inner face is held

// The phone's top-left corner, in the phone's own centred coordinates, measured off Apple's
// dimensional drawing: x across (+ to the right), y along (+ toward the camera end). It is a
// continuous-curvature corner, so it is carried as points. The other three corners are mirrors.
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

// The phone's outline, grown or shrunk by `extra`. Four mirrored copies of one corner, walked in
// order so the straight edges between them close the loop.
module phone_plan(extra = 0) {
    n = len(k_corner);
    offset(r = extra) polygon(concat(
        k_corner,
        [for (i = [n - 1 : -1 : 0]) [ k_corner[i][0], -k_corner[i][1]]],
        [for (i = [0 : n - 1])      [-k_corner[i][0], -k_corner[i][1]]],
        [for (i = [n - 1 : -1 : 0]) [-k_corner[i][0],  k_corner[i][1]]]
    ));
}

module src() { import(SRC, convexity = 10); }

// The same cut, move and bridge the other parts get: the piece outboard of each plane slides out,
// and the gap is filled by extruding the cut face straight. Every feature keeps its true size.
module sec_y(y) { projection(cut = true) translate([0, 0, -y]) rotate([90, 0, 0]) src(); }
module half_y(lo, hi) { intersection() { src(); translate([0, (lo + hi) / 2, 0]) cube([big, hi - lo, big], center = true); } }
module grown_y() {
    half_y(-yc, yc);
    translate([0,  dy, 0]) half_y(yc, big);
    translate([0, -dy, 0]) half_y(-big, -yc);
    translate([0, yc, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(yc);
    translate([0, -yc - dy, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(-yc);
}
module sec_x(x) { projection(cut = true) translate([0, 0, -x]) rotate([0, -90, 0]) grown_y(); }
module half_x(lo, hi) { intersection() { grown_y(); translate([(lo + hi) / 2, 0, 0]) cube([hi - lo, big, big], center = true); } }
module grown() {
    half_x(-xc, xc);
    translate([ dx, 0, 0]) half_x(xc, big);
    translate([-dx, 0, 0]) half_x(-big, -xc);
    translate([xc, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x(xc);
    translate([-xc - dx, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x(-xc);
}

difference() {
    grown();
    // The phone, held `squeeze` inside its real outline so the locator is compressed by that much.
    translate([0, 0, -big / 2])
        linear_extrude(height = big) phone_plan(-squeeze);
}
