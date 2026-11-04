// The door, remade for an iPhone 18 Pro Max.
//
// Three changes to upstream's iPhone 15 Pro door:
//   1. stretched +7 across and +12 along, on the same planes and by the same amounts as the shell
//      and carriage, so the hinge knuckles and latch tabs still line up with the shell's;
//   2. anything standing above the plate inside the phone's footprint is cleared, because the
//      upstream rim is sized for a 70.6 x 146.6 phone and this one is 78.0 x 163.4 -- it would
//      hold the phone out rather than hold it in;
//   3. the camera opening is cut to clear the camera plateau, and a recess is sunk for a MagSafe
//      ring.
//
// On (3): the dimensions come from Apple's own drawing -- the Accessory Design Guidelines point
// at a per-device library, and iPhone 18 Pro Max is published there as a dimensioned mechanical
// drawing (developer.apple.com/accessories/dimensional-drawings/, sheet dated 2026-09-09). It
// gives the body as 163.43 x 77.98 x 8.75, every imaging feature's centre and diameter, and the
// plateau standing 2.78 mm proud of the back plate with the camera glass 2.11 mm above that.
//
// The plateau figures here are a correction. An earlier pass had it running 0.8 .. 75.8 across,
// which forced an opening 77.00 mm wide on a 77.98 mm phone -- the full width, leaving no rim at
// the camera end at all. That 0.8 .. 75.8 is the ANTENNA KEEPOUT, a different region on the same
// sheet, marked "do not obstruct with metal or other conductive material (full product volume
// including sidewalls)"; it runs the full width and a little past it, and a PETG door, not being
// conductive, may cover it freely. The plateau itself is the raised shelf the door would foul,
// and it measures 3.79 .. 74.20 across -- 70.40 wide, inset 3.79 mm from each side wall.
//
// Both figures were measured the same way and the method is in README.md: the drawing converted
// to SVG, each path's own matrix applied, and the scale calibrated on the lens circles, whose
// centres Apple dimensions exactly. It checks out to 0.01 mm against the phone's stated size.

SRCDIR = "..";
SRC = str(SRCDIR, "/Door - Print-ready STLs - iPhone 15 Pro/Door - iPhone 15 Pro (PETG, outer face down).stl");

yc = 55; dy = 6;        // the shell's cut planes and inserts, exactly
xc = 26; dx = 3.5;
big = 400;

// Apple's figures, datum at the top-left of the phone's back, x across and y along.
phone_x = 77.98;
phone_y = 163.43;
fit     = 0.6;           // clearance around the phone
plate_top = 1.9;         // everything above this, inside the footprint, is cleared

// The camera plateau's footprint, measured off Apple's drawing. The lens centres it dimensions
// exactly (cameras at 14.37/14.37, 14.37/33.61 and 32.49/23.99, all 16.58 across; flash and rear
// sensor at 64.16/13.82 and 64.16/34.16, both 6.90) sit inside this, so clearing the plateau
// clears every one of them.
plateau_across = [3.79, 74.20];
plateau_along  = [0.0, 48.87];
plateau_margin = 1.2;    // clearance around the plateau

// Where the phone's centre sits in the door's own coordinates. It is not the door's centre: the
// door is asymmetric, with the hinge knuckles down one long side and the latch tabs down the
// other, so its outline is offset from the bay it covers. The figure is read off the door's own
// locator pockets, which are symmetric about the phone: they span -38.58 .. 36.87 across, whose
// middle is -0.855. Leaving this out skews every phone-referenced feature by that much.
phone_cx = -0.855;

// The opening, in the door's own coordinates: the plateau plus a margin all round, and past the
// phone's end so nothing laps over it.
cam_x0 = phone_cx + plateau_across[0] - plateau_margin - phone_x / 2;
cam_x1 = phone_cx + plateau_across[1] + plateau_margin - phone_x / 2;
cam_y0 = phone_y / 2 - plateau_along[1] - plateau_margin;
cam_y1 = phone_y / 2 + 1.3;

// The opening's corners are deliberately tighter than the plateau's own, which makes them reach
// further out: a corner that is too square clears the plateau and costs a little rim, where one
// that is too round would land on it.
cam_r = 8;

// MagSafe. Apple's drawing puts the magnet array at 57.50 across, centred 38.99 across and 81.72
// along -- the dead centre of the phone's back to within 5 microns. This is a recess in the outer
// face for a ring to sit in and be located by, not a hole: the plate is 1.9 mm thick here and
// Apple's note 8 allows a case up to 2.1 mm on the back for full functionality, so MagSafe already
// works through it and cutting through would only throw away the plate that holds the phone.
magsafe_d      = 57.50;
magsafe_clear  = 0.5;    // so a printed ring drops in rather than having to be pressed
magsafe_depth  = 0.8;    // of the 1.9 mm plate, leaving 1.1

// The locator pockets, as the stretch leaves them: upstream's are at -38.58..-24.48 and
// 21.47..36.87 across and +-56.92..78.72 along, and each edge moves by the same rule as everything
// else (past -26 by -3.5, past 26 by +3.5, past +-55 by +-6). They have to be cut again because
// the plate is filled back in below, which would otherwise close them.
pocket_r = 2;

// The strip filled back in, from the new opening's right edge out past where upstream's reaches.
fill_x1 = 41.0;
fill_y0 = 24.0;
fill_y1 = 85.0;   // short of the door's own end at 85.59, so the strip never stands proud
pockets = [
    [-42.08, -24.48, -84.72, -62.92],
    [-42.08, -24.48,  62.92,  84.72],
    [ 21.47,  40.37, -84.72, -62.92],
    [ 21.47,  40.37,  62.92,  84.72],
];

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
    union() {
        grown();

        // Fill the plate back in down the one strip where upstream's own opening is wider than
        // this one. The method only ever moves material, it never adds any, so upstream's opening
        // is still in this mesh and the two union: the hole ends up as wide as whichever is wider.
        // Stretched, upstream's reaches 40.37 across -- 2.24 mm past this phone's own edge -- so
        // without this the new opening would not narrow the hole at all.
        //   Only this strip, and not the whole footprint: the plate is perforated with a grid of
        // 2 mm holes that a footprint-wide fill would close (it takes the part from genus 677 to
        // 2). The perforations stop at 31.35 across, well clear of this strip.
        translate([(cam_x1 + fill_x1) / 2, (fill_y0 + fill_y1) / 2, plate_top / 2])
            cube([fill_x1 - cam_x1, fill_y1 - fill_y0, plate_top], center = true);
    }

    // (2) Clear the old rim: it is sized for a much smaller phone.
    translate([phone_cx, 0, plate_top + big / 2]) rrect(fx, fy, big);

    // (3) The camera opening, through the plate, clearing the whole plateau.
    translate([(cam_x0 + cam_x1) / 2, (cam_y0 + cam_y1) / 2, 0])
        rrect(cam_x1 - cam_x0, cam_y1 - cam_y0, big, cam_r);

    // (3) The MagSafe ring's recess, in the outer face, which is at z = 0 because the source STL
    // is the "outer face down" one.
    translate([phone_cx, phone_y / 2 - 81.72, -0.01])
        cylinder(h = magsafe_depth + 0.01, d = magsafe_d + magsafe_clear, $fn = 160);

    // The locator pockets, reopened through the fill.
    for (k = pockets)
        translate([(k[0] + k[1]) / 2, (k[2] + k[3]) / 2, 0])
            rrect(k[1] - k[0], k[3] - k[2], big, pocket_r);
}
