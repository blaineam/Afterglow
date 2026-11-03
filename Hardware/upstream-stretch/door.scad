// The door, remade for an iPhone 18 Pro Max.
//
// Three changes to upstream's iPhone 15 Pro door:
//   1. stretched +7 across and +12 along, on the same planes and by the same amounts as the shell
//      and carriage, so the hinge knuckles and latch tabs still line up with the shell's;
//   2. anything standing above the plate inside the phone's footprint is cleared, because the
//      upstream rim is sized for a 70.6 x 146.6 phone and this one is 78.0 x 163.4 -- it would
//      hold the phone out rather than hold it in;
//   3. the camera opening is cut deliberately oversized.
//
// On (3): the island's dimensions are not published in any form this file can rely on, and
// upstream's own cutout cannot be read back off the mesh because the door is perforated for
// ventilation and the vent gaps swamp the measurement. The rear camera is what drives passthrough,
// hand tracking and QR scanning, so an opening that is too small stops the app working while one
// that is too large only costs some support under the phone. So it is cut large, leaving a rim.

// Point SRCDIR at the unzipped MakerWorld download:
//   openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o door.stl door.scad
SRCDIR = "..";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/Door - iPhone 15 Pro (PETG, outer face down).stl");

yc = 55; dy = 6;        // the shell's cut planes and inserts, exactly
xc = 26; dx = 3.5;
big = 400;

phone_x = 78.0;         // iPhone 18 Pro Max
phone_y = 163.4;
fit = 0.6;              // clearance around the phone
plate_top = 1.9;        // everything above this, inside the footprint, is cleared

// The camera opening: full phone width less a rim, running from the camera end inward.
cam_rim = 4.0;          // material kept outside the opening, each side
cam_len = 52.0;         // how far in from the phone's end it reaches
cam_end_rim = 6.0;      // material kept at the very end of the phone's footprint

module src() { import(SRC, convexity = 12); }
module sec_y(y) { projection(cut = true) translate([0, 0, -y]) rotate([90, 0, 0]) src(); }
module half_y(lo, hi) { intersection() { src(); translate([0, (lo + hi) / 2, 0]) cube([big, hi - lo, big], center = true); } }
module grown_y() {
    half_y(-yc, yc);
    translate([0,  dy, 0]) half_y(yc, big);
    translate([0, -dy, 0]) half_y(-big, -yc);
    translate([0, yc, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(yc);
    translate([0, -yc - dy, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(-yc);
}
module sec_x2(x) { projection(cut = true) translate([0, 0, -x]) rotate([0, -90, 0]) grown_y(); }
module half_x(lo, hi) { intersection() { grown_y(); translate([(lo + hi) / 2, 0, 0]) cube([hi - lo, big, big], center = true); } }
module grown() {
    half_x(-xc, xc);
    translate([ dx, 0, 0]) half_x(xc, big);
    translate([-dx, 0, 0]) half_x(-big, -xc);
    translate([xc, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(xc);
    translate([-xc - dx, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(-xc);
}

module rrect(w, l, h, r = 6) {
    hull() for (sx = [-1, 1], sy = [-1, 1])
        translate([sx * (w / 2 - r), sy * (l / 2 - r), 0]) cylinder(h = h, r = r, center = true, $fn = 48);
}

fx = phone_x + fit;     // the phone's footprint on the door
fy = phone_y + fit;

difference() {
    grown();

    // (2) Clear the old rim: it is sized for a much smaller phone.
    translate([0, 0, plate_top + big / 2]) rrect(fx, fy, big);

    // (3) The camera opening, through the plate, at the camera end (+y).
    translate([0, fy / 2 - cam_end_rim - cam_len / 2, 0])
        rrect(fx - 2 * cam_rim, cam_len, big);
}
