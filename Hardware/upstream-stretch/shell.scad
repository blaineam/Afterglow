// Lengthens and widens brenpoly's viewer shell so an iPhone 18 Pro Max fits.
//
// The shell's phone bay measures 73.00 across by 154.18 along; the phone is 78.0 by 163.4, so the
// bay has to grow in both directions. The shell is contoured rather than extruded, so it cannot be
// scaled (that would move the lenses and turn their bores into ellipses). Instead it is cut, the
// outer pieces are moved out, and the gap is filled with the cut face extruded straight: the
// contour then carries a flat band the width of the insert, but every feature keeps its size and
// the lenses keep their spacing.
//
// Cuts go outboard of the lens bores (which sit at y = +/-32.2, about 14 mm across) so no bore is
// ever smeared.

// Point SRCDIR at the unzipped MakerWorld download:
//   openscad -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' ...
SRCDIR = "..";
SRC = str(SRCDIR, "/", "Main Shell - Print-ready STLs/Viewer shell (back face down).stl");

yc = 55;      // cut along the phone's long axis
dy = 6;       // inserted each side: +12 along
xc = 26;      // cut across it
dx = 3.5;     // inserted each side: +7 across

big = 400;

module src() { import(SRC, convexity = 12); }

// The solid's cross-section at y, as a 2D shape (rotate so that plane lands on z = 0, slice).
module sec_y(y) { projection(cut = true) translate([0, 0, -y]) rotate([90, 0, 0]) src(); }
module sec_x(x) { projection(cut = true) translate([0, 0, -x]) rotate([0, -90, 0]) src(); }

module half_y(lo, hi) { intersection() { src(); translate([0, (lo + hi) / 2, 0]) cube([big, hi - lo, big], center = true); } }

// Grown along the phone's long axis first.
module grown_y() {
    half_y(-yc, yc);
    translate([0,  dy, 0]) half_y(yc, big);
    translate([0, -dy, 0]) half_y(-big, -yc);
    translate([0, yc, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(yc);
    translate([0, -yc - dy, 0]) rotate([-90, 0, 0]) linear_extrude(height = dy) sec_y(-yc);
}

module half_x(lo, hi) { intersection() { grown_y(); translate([(lo + hi) / 2, 0, 0]) cube([hi - lo, big, big], center = true); } }

// Then across it, on the already-lengthened shell.
module grown() {
    half_x(-xc, xc);
    translate([ dx, 0, 0]) half_x(xc, big);
    translate([-dx, 0, 0]) half_x(-big, -xc);
    translate([xc, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(xc);
    translate([-xc - dx, 0, 0]) rotate([0, 90, 0]) linear_extrude(height = dx) sec_x2(-xc);
}

// Sections of the lengthened shell, not the original, since the x cuts come second.
module sec_x2(x) { projection(cut = true) translate([0, 0, -x]) rotate([0, -90, 0]) grown_y(); }

grown();
