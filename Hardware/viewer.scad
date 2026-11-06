// A phone VR viewer for Afterglow, parametric in the phone.
//
// Why this exists: the viewer this project was built around is published as print files only, one
// set per phone, with no CAD source, so a new phone cannot be added to it. This is a separate
// design whose geometry comes from a table, so a phone is a row rather than a redraw.
//
// It is built around Cardboard v2 lenses (25 mm, about 34 mm focal length), the same lenses that
// viewer uses, because the app's lens distortion is the Cardboard SDK's and its built-in profile
// for them is exact (ViewerParams.CardboardV2).
//
// One difference worth knowing: the lenses are centred on the screen rather than sitting above a
// bottom tray as a Cardboard viewer's do. Cardboard's bottom alignment puts the optical axis
// 32 mm up a 73 mm screen, which costs vertical view at the bottom (about 50 degrees against the
// lens's 60); centred, both halves reach about 58. That is why the app needs the matching profile
// below and not the stock Cardboard one.
//
//   openscad -D 'part="body"'  -o body.stl  viewer.scad
//   openscad -D 'part="plate"' -o plate.stl viewer.scad
//   openscad -D 'part="door"'  -o door.stl  viewer.scad
//
// Print: PLA or PETG, 0.2 mm layers, 3 perimeters, no supports needed in these orientations.
// The body prints face-down (its open face on the plate).

// ---------------------------------------------------------------------------- what to export
part = "body";                 // "body", "plate", "door", or "preview"

// ---------------------------------------------------------------------------- the phone
// Body size and active screen area in mm. The screen area is pixels / ppi * 25.4, landscape, and
// decides where the lip can rest without covering anything.
//   iPhone 18 Pro Max  163.4 x 78.0 x 8.75   2868 x 1320 at 460 ppi
//   iPhone 16 Pro Max  163.4 x 78.0 x 8.25   2868 x 1320 at 460 ppi
//   iPhone 15 Pro      146.6 x 70.6 x 8.25   2556 x 1179 at 460 ppi
//   iPhone 16 Pro      149.6 x 71.5 x 8.25   2622 x 1206 at 460 ppi
phone_length    = 163.4;
phone_width     = 78.0;
phone_thickness = 8.75;
screen_length   = 158.4;
screen_width    = 72.9;

// How much bigger than the phone its pocket is, total across each axis.
phone_clearance = 0.6;
// How far the window's edge is kept off the active area, per side, so the lip rests on bezel only.
screen_margin = 0.5;

// ---------------------------------------------------------------------------- the lenses
lens_diameter     = 25.0;      // Cardboard v2
lens_seat_depth   = 3.0;       // pocket the lens drops into, from the screen side
lens_bore         = 23.0;      // what you look through; smaller than the lens, which it retains
inter_lens        = 63.9;      // ViewerParams.CardboardV2.interLensDistance, in mm

// Focus: how far the lens carriage can travel, around the profile's nominal screen-to-lens.
screen_to_lens_nominal = 39.3; // ViewerParams.CardboardV2.screenToLensDistance, in mm
focus_travel           = 6.0;  // either way

// ---------------------------------------------------------------------------- the shell
wall         = 2.4;
plate_height = 60.0;           // the carriage's height; must clear the lenses and the channels
plate_thick  = 6.0;
slide_depth  = 2.0;            // how far the channel is cut into each side wall
fit          = 0.4;            // sliding clearance, total
eye_relief   = 16.0;           // lens face to the viewer's own face
nose_width   = 34.0;           // must stay under the gap between the lenses
nose_height  = 22.0;
nose_depth   = 34.0;           // how far back from the face the notch runs
strap_slot   = [25.0, 4.0];    // for a 25 mm strap
door_inset   = 2.0;            // the door's thickness, and how deep its recess is
door_bar     = 20.0;           // the bar across the phone's back, which is all that holds it

$fn = 72;

// ---------------------------------------------------------------------------- derived
pocket_l = phone_length + phone_clearance;
pocket_w = phone_width + phone_clearance;
pocket_d = phone_thickness + phone_clearance;

// The window the lip leaves over the screen: wider than the active area, narrower than the pocket.
window_l = screen_length + 2 * screen_margin;
window_w = screen_width + 2 * screen_margin;

outer_l = pocket_l + 2 * wall;
outer_w = pocket_w + 2 * wall;

// Z runs from the screen, at 0, toward the face. The phone is behind it.
back_z  = -(pocket_d + wall);
// Where the carriage's back face may sit, and so how deep the shell has to be.
slide_back  = screen_to_lens_nominal - focus_travel - lens_seat_depth / 2;
slide_front = screen_to_lens_nominal + focus_travel - lens_seat_depth / 2 + plate_thick;
front_z = slide_front + eye_relief;

// The door's own outline: the recess it drops into, less a sliding clearance.
door_l = outer_l - 2 * wall + 2 * door_inset - fit;
door_w = outer_w - 2 * wall + 2 * door_inset - fit;

// The carriage rides in channels cut into the side walls, so it is wider than the window.
plate_l = window_l + 2 * slide_depth - fit;
// How far the thumb slot cuts, from the cavity wall out past the shell's face.
thumb_reach = outer_l / 2 + 1 - window_l / 2;

module rounded_box(size, radius) {
    hull() for (x = [-1, 1], y = [-1, 1])
        translate([x * (size[0] / 2 - radius), y * (size[1] / 2 - radius), 0])
            cylinder(h = size[2], r = radius, center = true);
}

// The shell: a tube open at the face, with the phone's pocket at the back behind a lip, the
// carriage's channels in its side walls, a notch for the nose and slots for a strap.
module body() {
    difference() {
        translate([0, 0, (front_z + back_z) / 2])
            rounded_box([outer_l, outer_w, front_z - back_z], 4);

        // The phone's pocket, from the open back right up to the screen plane at Z = 0. It has to
        // reach the screen plane: stopping at the phone's own thickness leaves a wall across its
        // face, and the lip that holds the phone comes from the window being smaller, not from this.
        translate([0, 0, back_z / 2])
            cube([pocket_l, pocket_w, -back_z + 0.02], center = true);

        // Everything in front of the screen, which the lip's edge defines.
        translate([0, 0, front_z / 2])
            cube([window_l, window_w, front_z + 0.02], center = true);

        // The channels the carriage slides along, one in each side wall.
        for (side = [-1, 1])
            translate([side * (window_l + slide_depth) / 2, 0, (slide_back + slide_front) / 2])
                cube([slide_depth + 0.02, plate_height, slide_front - slide_back], center = true);

        // A thumb slot each side, so the carriage can be pushed without taking the phone out. It
        // runs from inside the cavity out through the wall, so it meets the channel: a slot that
        // only cuts the wall leaves the carriage's edge still buried behind 0.3 mm of plastic.
        for (side = [-1, 1])
            translate([side * (window_l / 2 + thumb_reach / 2), 0, (slide_back + slide_front) / 2])
                cube([thumb_reach, 20, slide_front - slide_back], center = true);

        // The nose notch, in the bottom wall at the face end.
        translate([0, -outer_w / 2, front_z - nose_depth / 2 + 0.01])
            rounded_box([nose_width, 2 * nose_height, nose_depth], 6);

        // Strap slots, through both side walls near the face.
        for (side = [-1, 1])
            translate([side * outer_l / 2, 0, front_z - 14])
                cube([2 * wall + 0.02, strap_slot[0], strap_slot[1]], center = true);

        // The recess the door drops into: one door thick, at the very back, and only out to the
        // ring's outline, so a shoulder is left inside it for the ring to rest on.
        translate([0, 0, back_z + door_inset / 2 - 0.01])
            difference() {
                cube([door_l + fit, door_w + fit, door_inset + 0.02], center = true);
                cube([pocket_l, pocket_w, door_inset + 0.04], center = true);
            }
    }
}

// The lens carriage: a plate with a seat for each lens, which slides in the body's channels to
// focus. Friction holds it; `fit` is the only clearance.
module plate() {
    difference() {
        cube([plate_l, plate_height - fit, plate_thick], center = true);
        for (side = [-1, 1])
            translate([side * inter_lens / 2, 0, 0]) {
                // What you look through, all the way.
                cylinder(h = plate_thick + 0.02, d = lens_bore, center = true);
                // The pocket the lens drops into, open toward the screen.
                translate([0, 0, -(plate_thick - lens_seat_depth) / 2 - 0.01])
                    cylinder(h = lens_seat_depth + 0.02, d = lens_diameter + 0.3, center = true);
            }
    }
}

// The door: a ring that sits in the body's recess, with one bar across the middle of the phone's
// back. Both ends of the phone stay completely open, and so does everything but a strip at the
// centre.
//   That shape is deliberate. The rear camera is what the app uses for passthrough, hand tracking
// and reading a viewer's QR code, so a door that clipped the camera island would not look wrong,
// it would stop the tracking working. The island sits at one end of the phone and its size is not
// published in any form this file could rely on, so rather than cut an opening sized from a guess,
// the door holds the phone where no phone has a camera: across the middle.
module door() {
    union() {
        // The ring, which rests on the shoulder the body's recess leaves.
        difference() {
            cube([door_l, door_w, door_inset], center = true);
            cube([pocket_l, pocket_w, door_inset + 0.2], center = true);
        }
        // The bar, reaching the ring top and bottom so the part comes off the plate in one piece.
        cube([door_bar, door_w, door_inset], center = true);
    }
}

if (part == "body") body();
else if (part == "plate") plate();
else if (part == "door") door();
else {
    // Laid out as assembled, for a look before printing.
    body();
    #translate([0, 0, slide_back + plate_thick / 2]) plate();
    #translate([0, 0, back_z + door_inset / 2]) door();
}
