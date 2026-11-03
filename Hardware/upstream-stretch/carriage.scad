// The lens carriage, stretched to match the stretched shell. Same method: cut outboard of the
// lens bores (y = +/-32.2, about 28 across, so nothing is cut inside +/-46), move the outer
// pieces, and bridge with the cut face extruded straight. The bores, and so the lens spacing that
// the app's viewer profile is built on, are untouched.

// Point SRCDIR at the unzipped MakerWorld download:
//   openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' ...
SRCDIR = "..";
SRC = str(SRCDIR, "/", "Main Shell - Print-ready STLs/Lens carriage (face side down).stl");

yc = 55;    // the same plane the shell is cut on, so mating features move together
dy = 6;     // +12 along, matching the shell
xc = 26;
dx = 3.5;   // +7 across, matching the shell
big = 400;

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
grown();
