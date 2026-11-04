// TPU corner locators for the iPhone 18 Pro Max: the soft parts that take up the play between the
// phone and the shell's bay.
//
// Upstream ships four per phone, one per corner. This makes TWO, both at the USB end.
//
// The camera-end pair are gone, and not for want of trying. Two things rule them out, either of
// which would be enough. The gap between the phone's corner and the bay wall at that end measures
// 1.87 mm where the phone is still full width and only opens up as the corner curves away, against
// a locator 15.87 mm wide. And the inboard half of the pocket that would hold one lies under the
// camera plateau, which has to be cut through. The door grows a rigid collar there instead -- see
// `end_collar` in door.scad -- which is what fits in 1.9 mm.
//
// These are also a remake. The first version built the locators from scratch out of bay-minus-phone
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
//   openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' \
//            -D 'part="usb-top"' -o locator-usb-top.stl locators.scad
//
// Print in TPU. See README.md for why they are not printed in one piece with the door.

include <phone.scad>

SRCDIR = "..";
part = "usb-top";             // usb-top, usb-bottom

// Which of upstream's four this one is remade from. The two are not interchangeable.
corner_file = part == "usb-top" ? "top - USB-end" : "bottom - USB-end";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/TPU locator - ", corner_file, " corner.stl");

// The shell's cut planes and inserts, exactly as door.scad and shell.scad use them.
yc = 55; dy = 6;
xc = 26; dx = 3.5;
big = 400;

// `squeeze` is the one number that is a choice: the inner face is held that far inside the phone's
// outline, so the locator is compressed when the phone goes in, instead of letting it rattle.
//
// IT DEPENDS ON THE FILAMENT, and the default here is the stiff one. Bambu's "TPU for AMS" is a
// Shore 68D formulation -- a semi-rigid engineering material, not a bumper -- and asking it to give
// up 0.6 mm would either refuse to go in or push the phone around. 0.15 mm is a close fit with a
// little give, which is what 68D can actually do.
//
//   TPU for AMS (68D), the AMS-feedable one   squeeze = 0.15
//   ordinary TPU 95A, external spool only     squeeze = 0.60
//
// 0.60 is upstream's own figure in spirit: their iPhone 15 Pro locator stands 1.81 mm proud of the
// phone corner into a 1.20 mm gap, which is 0.61 mm of the same thing, in 95A.
squeeze = 0.15;

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
