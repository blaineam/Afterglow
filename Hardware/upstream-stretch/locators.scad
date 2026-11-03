// TPU corner locators for the iPhone 18 Pro Max, the soft parts that take up the play between the
// phone and the shell's bay. Upstream ships four per phone and they are, with the door's camera
// opening, the whole of what makes a door phone-specific.
//
// Print in TPU. They are deliberately a little thicker than the gap, so they go in with a squeeze
// and damp the phone rather than letting it rattle; upstream's do the same (its iPhone 15 Pro
// locator stands 1.81 mm proud of the phone corner into a 1.20 mm gap).

part = "camera-top";     // camera-top, camera-bottom, usb-top, usb-bottom, or all

// Apple's figures, from the dimensional drawing (see README).
phone_x = 77.98;
phone_y = 163.43;
bay_x   = 80.00;         // the stretched shell's bay
bay_y   = 166.18;
squeeze = 0.6;           // how far past the bay it stands before being pressed in
arm_x   = 16.0;          // how far the arms run along each edge of the phone
arm_y   = 18.0;
h       = 7.6;           // up the side of the phone, clear of the door's plate

px = phone_x / 2;
py = phone_y / 2;
ox = bay_x / 2 + squeeze;
oy = bay_y / 2 + squeeze;

// One corner, in the +x +y quadrant: the corner block with the phone's own corner taken out of it.
module corner() {
    difference() {
        translate([(px - arm_x + ox) / 2, (py - arm_y + oy) / 2, h / 2])
            cube([ox - px + arm_x, oy - py + arm_y, h], center = true);
        translate([px - 400, py - 400, -1]) cube([400, 400, h + 2]);
    }
}

module at(sx, sy) { mirror([sx < 0 ? 1 : 0, 0, 0]) mirror([0, sy < 0 ? 1 : 0, 0]) corner(); }

if (part == "camera-top")         at( 1,  1);
else if (part == "camera-bottom") at(-1,  1);
else if (part == "usb-top")       at( 1, -1);
else if (part == "usb-bottom")    at(-1, -1);
else { at(1,1); at(-1,1); at(1,-1); at(-1,-1); }
