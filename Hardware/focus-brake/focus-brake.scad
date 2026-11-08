// Focus click-and-lock for brenpoly's Mobile VR viewer (and the stretched iPhone 18 Pro Max remix).
//
//   PART = "wheel"    replacement focus wheel: 60 teeth on the rim, clears the shell's old nub
//   PART = "clip"     hooks through the shell's wheel slot; carries the click pawl
//   PART = "slider"   wedge that blocks the pawl from lifting: the positive lock
//   PART = "assembly" preview only (needs the shell, carriage and door STLs)
//
// Derived from upstream's wheel (the pinion is imported from it), so the output is CC BY-NC-SA.
// All clip and slider numbers are measured off the published meshes; see README.md.
//
//   openscad --backend=manifold -D 'PART="wheel"' \
//     -D 'SRCDIR="/path/to/Mobile+VR+viewer+for+modern+smartphones"' -o focus-wheel.stl focus-brake.scad
//   openscad --backend=manifold -D 'PART="clip"'   -o clip.stl   focus-brake.scad
//   openscad --backend=manifold -D 'PART="slider"' -o slider.stl focus-brake.scad

PART = "clip";
SRCDIR = "..";
FIRMNESS = 1;              // 0 soft, 1 standard, 2 firm: picks the pawl beam thickness below

/* [Parts as printed]
   Each part is exported in its print orientation. The clip and slider are drawn in the plane of
   the wheel: X is radial out through the shell wall, Z runs from the door (-) to the face (+), and
   the origin is the wheel's axle. The clip extrudes along y, downward from its bed face, so every
   flexure bends in the print plane and never across layer lines. */

/* Measured on the shell (axle-relative, unchanged by the stretch: axle and wall moved together) */
wall_x   = 9.10;     // outer face of the wall carrying the slot (x 42.10 stretched, 38.60 upstream)
wall_in  = 7.30;     // inner face at the slot's door end (x 40.30 stretched)
slot_z   = 11.30;    // slot ends at Z = +/-11.30 (z 12.95 and 35.55)
slot_y   = 3.00;     // slot sides at y = +/-3.00
foot_z   = -15.65;   // door-side limit of the clip (z 8.60): keeps it clear of the elastic door cord

/* Wheel */
teeth    = 60;       // 30.16 mm of rack per turn / 60 = 0.503 mm of focus per click
r_tip    = 13.00;    // same outside radius as upstream, so slot and carriage clearances are unchanged
tip_flat = 0.15;
rim_y0   = -2.50;    // the rim's limits along the axle, y in the assembly frame
rim_y1   = 0.50;     // upstream's rim ran to +2.50; the 2 mm saved is what the clip's tongue uses
hub_r    = 6.50;
wheel_y1 = 8.00;
bore_r   = 1.60;     // upstream 1.70. Tighter, so the pawl's load doesn't just shift the wheel on its axle
relief_r0 = 9.20;    // groove over the shell's old nub, which spans r 9.51..11.45 at its base
relief_r1 = 11.70;
relief_d  = 1.40;    // nub reaches 1.03 past y=-3.00; wheel can float 0.50 toward it; 0.37 to spare

/* Pawl */
th       = 15;       // pawl sits 15 degrees door-side of the top of the wheel
r_in     = 13.35;    // beam's inner face, clears the tooth tips by 0.35
beam_t   = [0.90, 1.05, 1.15][FIRMNESS];
s_root   = 11.20;    // beam's free length, tooth to root
head_top = 14.60;
preload  = 0.20;     // pawl is drawn this far into the valley; flanks stop it, so the beam rests just lifted
tip_w    = 0.20;

/* Lock channel, in (r, s): r radial, s along the beam, toward its root */
arch_in  = 15.15;
arch_out = 17.30;
cav_r0   = 15.65;  cav_r1 = 16.45;     // slider flange lives here
cav_s0   = -2.75;  cav_s1 =  2.55;
neck_s0  = -1.70;  neck_s1 = 1.50;     // slider rib passes through to reach the pawl head
wall_s0  = -3.50;  wall_s1 = 3.30;

/* Clip in y (print stack runs from +y down to -y) */
y_bed    = 2.85;     // clears the slot side by 0.15
y_tongue = 1.00;     // tongue and hook between here and y_bed; 0.50 clear of the rim
y_head   = -2.60;
y_open   = -2.75;    // the roof stops here, and the leaf has room...
y_cap0   = -7.00;    // ...until the cap, which catches the leaf's bumps
y_end    = -8.00;

/* Slider */
wedge_deg = 8;       // self-locks at any friction above 0.14; PETG on PETG is about 0.25
rib_s0   = -1.55;  rib_s1 = 1.35;
fl_s0    = -2.60;  fl_s1  = 2.40;
fl_r0    = 15.75;  fl_r1  = 16.35;
tip_r    = 15.10;    // rib's underside at the tip
rib_low  = 14.35;
leaf_r0  = 16.75;  leaf_r1 = 17.25;
bump_h   = 0.30;
cap_r0   = 17.35;  cap_r1  = 18.00;
L_pad    = 9.60;     // tip to the thumb pad
pad_len  = 6.00;
pad_top  = 18.50;
leaf_l   = 6.15;

/* Helpers */
function P(r, s) = [r * cos(th) - s * sin(th), -r * sin(th) - s * cos(th)];
module rs_box(r0, r1, s0, s1) { polygon([P(r0, s0), P(r1, s0), P(r1, s1), P(r0, s1)]); }

// everything above the wall, on the door side of the foot limit
module keep() { translate([wall_x, foot_z]) square([40, 60]); }

module pawl_tooth() {
    r_free = (r_tip - (PI * r_tip / teeth - tip_flat / 2)) + tip_w / 2 - preload;
    hw = (r_in - r_free) + tip_w / 2;
    polygon([P(r_free, -tip_w / 2), P(r_free, tip_w / 2), P(r_in + 0.05, hw), P(r_in + 0.05, -hw)]);
}

module channel() {
    difference() {
        rs_box(arch_in, arch_out, wall_s0, wall_s1);
        rs_box(cav_r0, cav_r1, cav_s0, cav_s1);
        rs_box(arch_in - 1, cav_r0 + 0.01, neck_s0, neck_s1);
    }
}

module arch() { rs_box(arch_in, arch_out, wall_s1 - 0.01, s_root + 8); }

// the foot and the wedge joining beam and arch at the root
module foot() {
    polygon([[wall_x, foot_z], [wall_x, -12.70], P(r_in, s_root), P(r_in + beam_t, s_root),
             P(arch_in, s_root), P(arch_out, s_root + 8), [wall_x, foot_z - 4]]);
}

module beam() {
    rs_box(r_in, r_in + beam_t, -1.5, s_root + 0.6);
    rs_box(r_in, head_top, -1.5, 1.3);
    pawl_tooth();
}

module root_voids() {
    // rounds the root's two inside corners, where the bending stress peaks
    offset(r = 0.60) offset(delta = -0.60)
        polygon([P(r_in, s_root), P(r_in, 1.5), [wall_x - 2, -6], [wall_x - 2, -12.70], [wall_x, -12.70]]);
    offset(r = 0.20) offset(delta = -0.20)
        rs_box(r_in + beam_t, arch_in, 1.31, s_root);
}

// the profile in every band; merge() fuses anything that only touches along a line
module merge() { offset(delta = -0.004) offset(delta = 0.004) offset(delta = 0.004) offset(delta = -0.004) children(); }

module body2d(with_beam) {
    merge() intersection() {
        keep();
        difference() {
            union() { arch(); channel(); foot(); if (with_beam) beam(); }
            if (with_beam) root_voids();
            rs_box(cav_r0, cav_r1, cav_s0, cav_s1);
            rs_box(arch_in - 1, cav_r0 + 0.01, neck_s0, neck_s1);
            if (!with_beam) rs_box(r_in - 1, arch_in - 0.01, -3, s_root - 1);
        }
    }
}

// The bits that only exist beside the rim, in the slot: spine, tongue, hook, and the keeper that
// stops the clip sliding back off its hook.
module slot_side2d() {
    // spine, on the outside of the wall
    translate([wall_x, foot_z]) square([0.85, 16.45]);
    // tongue, in the slot; its door end stops short of the slot's end so the hook's ramp can tighten
    translate([7.40, -10.95]) square([wall_x - 7.40 + 0.1, 19.35]);
    // hook: behind the wall's inner face, with an 18 degree ramp that takes up the wall's tolerance
    polygon([[7.42, -10.70], [7.42, -10.95], [7.30, -11.30], [6.82, -12.75], [5.85, -12.75],
             [5.85, -11.90], [7.40, -9.90]]);
    // keeper: a light beam ending in a block that drops into the slot's far end
    keeper2d();
}

module keeper2d() {
    translate([9.35, 0.0]) square([1.00, 10.0]);      // beam, 10 mm, lifts by hand
    translate([wall_x - 0.3, 0.0]) square([0.6, 0.8]); // root
    polygon([[8.40, 9.10], [8.40, 10.55], [9.15, 11.32], [9.40, 11.60], [11.40, 11.60], [11.40, 10.10], [10.35, 9.10]]);
}

// The band beyond the rim where the leg rests on the wall, chamfered so it prints without support
module leg() {
    a = P(arch_in + 0.05, wall_s0);
    hull() {
        translate([a[0] - 0.37, a[1] - 0.23, y_bed - y_open]) cube([0.3, 1.2, 0.01]);
        translate([wall_x, a[1] - 0.23, y_bed - (y_end + 0.6)]) cube([a[0] - wall_x - 0.07, 1.2, 0.6]);
    }
}

// y_open .. y_cap0: the roof stops, so the slider's leaf has room to flex
module band_open2d() {
    merge() difference() { body2d(false); rs_box(cav_r1 - 0.01, arch_out + 1, cav_s0, cav_s1); }
}

// y_cap0 .. y_end: walls carry on up and a bridge across them catches the leaf's bumps
module band_cap2d() {
    merge() difference() {
        union() { body2d(false); rs_box(arch_in + 1, cap_r1, wall_s0, cav_s0 + 0.01); rs_box(arch_in + 1, cap_r1, cav_s1 - 0.01, wall_s1);
                  rs_box(cap_r0, cap_r1, wall_s0, wall_s1); }
        rs_box(cav_r1 - 0.01, cap_r0, cav_s0, cav_s1);
    }
}

// Each band is inset a few microns on the last, so no two walls are coplanar and every edge in the
// export belongs to exactly two faces.
module band(y0, y1, inset) {
    translate([0, 0, y_bed - y1 - 0.005]) linear_extrude(height = y1 - y0 + 0.01, convexity = 8)
        offset(delta = -inset) children();
}

module clip() {
    band(y_tongue, y_bed - 0.005, 0) merge() { body2d(true); slot_side2d(); }
    band(y_head, y_tongue, 0.004) body2d(true);
    band(y_open, y_head, 0.008) body2d(false);
    band(y_cap0, y_open, 0.012) band_open2d();
    band(y_end, y_cap0, 0.016) band_cap2d();
    leg();
}

/* Slider, drawn in (L, r): L from the tip rearward. Printed on its side, stacked along s. */
module slider_flange2d() {
    polygon([[0.3, fl_r0], [L_pad, fl_r0], [L_pad, fl_r1], [0.3, fl_r1]]);
    translate([L_pad, fl_r0]) square([pad_len, pad_top - fl_r0]);
}

module slider_leaf2d() {
    // Two bumps straddle the cap when unlocked, with the leaf unloaded. The front bump's back face is
    // steep: it is the stop that keeps the slider from walking out.
    x0 = L_pad - leaf_l;
    h = leaf_r1 + bump_h;
    polygon([[L_pad + 0.1, leaf_r0], [x0, leaf_r0], [x0, leaf_r1],
             [x0 + 0.35, h], [x0 + 0.62, h], [x0 + 0.70, leaf_r1],
             [x0 + 1.80, leaf_r1],
             [x0 + 2.10, h], [x0 + 2.20, h], [x0 + 2.50, leaf_r1],
             [L_pad + 0.1, leaf_r1]]);
}

module slider_rib2d() {
    k = tan(wedge_deg);
    L_flat = (tip_r - rib_low) / k;
    polygon([[0, cav_r0], [0, tip_r + 0.25], [0.5, tip_r], [L_flat, rib_low], [L_flat + 1.5, rib_low],
             [L_flat + 2.0, fl_r0 + 0.01], [L_flat + 2.0, cav_r0 + 0.2], [0, cav_r0 + 0.2]]);
}

module slider() {
    // stack: from fl_s1 down to fl_s0 (a proper rotation into the assembly, not a mirror).
    // Rib's lower side is chamfered 45 degrees so it needs no support.
    sw = fl_s1 - fl_s0;
    linear_extrude(height = sw) slider_flange2d();
    linear_extrude(height = sw) slider_leaf2d();
    difference() {
        translate([0, 0, fl_s1 - rib_s1]) linear_extrude(height = rib_s1 - rib_s0) slider_rib2d();
        // chamfer on the bed side of the rib
        multmatrix([[1, 0, 0, -1], [0, 1, 0, fl_r0], [0, 0, 1, fl_s1 - rib_s1], [0, 0, 0, 1]])
            rotate([90, 0, 90]) linear_extrude(height = 20) polygon([[0.01, -0.01], [-1.45, -0.01], [-1.45, 1.45]]);
    }
    // grip ridges on the pad, for a thumb that can't see it
    for (i = [0 : 3]) translate([L_pad + 0.6 + i * 1.35, pad_top - 0.01, 0]) linear_extrude(height = sw)
        polygon([[0, 0], [0.45, 0.5], [0.9, 0]]);
}

/* Wheel: prints with the relief groove down, as upstream's did with its notches */
function tooth_pts(i) = let (a = 360 * i / teeth, da = 360 / teeth, hf = tip_flat / 2 / r_tip * 180 / PI,
                            d = PI * r_tip / teeth - tip_flat / 2, rv = r_tip - d)
    [[r_tip * cos(a - hf), r_tip * sin(a - hf)], [r_tip * cos(a + hf), r_tip * sin(a + hf)],
     [rv * cos(a + da / 2), rv * sin(a + da / 2)]];

module rim2d() { polygon([for (i = [0 : teeth - 1]) each tooth_pts(i)]); }

module wheel() {
    bed = rim_y0;
    h_rim = rim_y1 - rim_y0;
    h5 = 5.0;       // upstream's pinion starts here, at y = 2.50
    difference() {
        union() {
            intersection() {
                linear_extrude(height = h_rim, convexity = 4) rim2d();
                // small chamfers: first layer doesn't flare into the slot, top edge is kind to a thumb
                rotate_extrude($fn = 240)
                    polygon([[0, 0], [r_tip - 0.40, 0], [r_tip + 0.05, 0.45], [r_tip + 0.05, h_rim - 0.30],
                             [r_tip - 0.30, h_rim], [0, h_rim]]);
            }
            cylinder(r = hub_r, h = h5 + 0.01, $fn = 96);
            cylinder(r = 3.81, h = wheel_y1 - bed, $fn = 96);
            // pinion: upstream's teeth, so the rack mesh is what was measured
            intersection() {
                import(str(SRCDIR, "/Main Shell - Print-ready STLs/Focus wheel (chamfered rim down).stl"), convexity = 8);
                translate([0, 0, h5 + 0.002]) cylinder(r = 8, h = 6, $fn = 48);
            }
        }
        translate([0, 0, -1]) cylinder(r = bore_r, h = 14, $fn = 64);
        // groove over the shell's old nub
        rotate_extrude($fn = 240)
            polygon([[relief_r0, -0.01], [relief_r1, -0.01], [relief_r1 - 0.1, relief_d], [relief_r0 + 0.7, relief_d]]);
    }
}

/* Assembly preview: asm(x, y, z) = (33 + X, y_bed - pz, 24.25 + Z) */
// SHELL_STL and CARRIAGE_STL are in the assembly frame: shell STL + (0.25, 0, -0.5)
SHELL_STL = ""; CARRIAGE_STL = ""; WHEEL_STL = "focus-wheel.stl"; CLIP_STL = "clip-standard.stl"; SLIDER_STL = "slider.stl";
TIP_Y = -2.80;   // -2.80 unlocked, about 0.0 locked
module to_asm() { multmatrix([[1, 0, 0, 33], [0, 0, -1, y_bed], [0, 1, 0, 24.25], [0, 0, 0, 1]]) children(); }

module assembly() {
    if (SHELL_STL != "") color([0.38, 0.38, 0.42]) import(SHELL_STL, convexity = 10);
    if (CARRIAGE_STL != "") color([0.2, 0.42, 0.85]) import(CARRIAGE_STL, convexity = 10);
    multmatrix([[1, 0, 0, 33], [0, 0, 1, rim_y0], [0, -1, 0, 24.25], [0, 0, 0, 1]]) color([0.85, 0.25, 0.2]) import(WHEEL_STL, convexity = 8);
    to_asm() color([0.95, 0.72, 0.2]) import(CLIP_STL, convexity = 8);
    slider_to_asm(TIP_Y) color([0.25, 0.75, 0.45]) import(SLIDER_STL, convexity = 8);
}

// slider (L, r, pz) -> asm. L = TIP_Y - y; r, s rotate by th about the axle.
module slider_to_asm(tip_y) {
    translate([33, tip_y, 24.25]) multmatrix([
        [0, cos(th), sin(th), -fl_s1 * sin(th)],
        [-1, 0, 0, 0],
        [0, -sin(th), cos(th), -fl_s1 * cos(th)],
        [0, 0, 0, 1]]) children();
}

if (PART == "wheel") wheel();
else if (PART == "clip") clip();
else if (PART == "slider") slider();
else if (PART == "assembly") assembly();

// Worked numbers, printed on every run so a change of parameter shows its effect at once.
// k = E w t^3 / (4 L^3), with E = 1800 MPa, printed PETG bent in the layer plane
beam_w = y_bed - y_head;
k_pawl = 1800 * beam_w * pow(beam_t, 3) / (4 * pow(s_root, 3));
echo(str("pawl beam t ", beam_t, " mm, k = ", k_pawl, " N/mm; strain at 0.69 lift = ", 1.5 * beam_t * 0.69 / pow(s_root, 2) * 100, " %"));
echo(str("travel per click = ", PI * 9.6 / teeth, " mm"));
