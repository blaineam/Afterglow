// A WebXR implementation for pages shown inside Afterglow's browser.
//
// Safari has no WebXR on iOS -- not in 26, not in 27; immersive sessions are Vision Pro only -- so
// a page opened here finds no navigator.xr and falls back to a flat view. This supplies one.
//
// It is not a polyfill of the usual kind, which reads the phone's own orientation sensors through
// DeviceOrientation. The app around this page already has a fused head pose (gyroscope corrected
// by ARKit), which is better than anything the page could get for itself, and it pushes that pose
// in through __afterglowPose. What this file does is turn that pose, and the viewer's measured
// optics, into the matrices a WebXR page expects, split the canvas into two eyes, and -- after the
// page has drawn -- warp both halves through the lenses' barrel distortion.
//
// The distortion is ported from this project's own LensDistortion.cs, which is itself ported from
// the Cardboard SDK (sdk/lens_distortion.cc, sdk/polynomial_radial_distortion.cc, Apache 2.0), so
// a page here is corrected with exactly the numbers the native app corrects itself with.
//
// What it does not do: hit testing, anchors, planes, depth, bounded or unbounded
// reference spaces, or anything AR. Pages built on three.js or A-Frame that ask for an
// immersive-vr session, a local or viewer reference space and a WebGL layer will run. Pages that
// reach past that will not, and should fail honestly rather than silently.

(function () {
    'use strict';

    if (navigator.xr) return;                       // a real implementation; leave it alone
    var cfg = window.__afterglowConfig;
    if (!cfg) return;                               // not running inside the app

    var MESH = 40;                                  // LensDistortion.MeshResolution
    var DEG = Math.PI / 180;

    // ---------------------------------------------------------------- the lenses
    // p' = p (1 + K1 r^2 + K2 r^4 + ...), r in tan-angle units.
    function distortionFactor(r2) {
        var factor = 1, radius = 1;
        for (var i = 0; i < cfg.k.length; i++) { radius *= r2; factor += cfg.k[i] * radius; }
        return factor;
    }
    function distortRadius(r) { return r * distortionFactor(r * r); }

    // Solves distort(result) = radius by the secant method, as the SDK does.
    function distortInverse(x, y) {
        var radius = Math.sqrt(x * x + y * y);
        if (radius < 1e-9) return [0, 0];
        var r0 = radius / 2, r1 = radius / 3, dr0 = radius - distortRadius(r0);
        for (var i = 0; i < 100 && Math.abs(r1 - r0) > 0.0001; i++) {
            var dr1 = radius - distortRadius(r1);
            var r2 = r1 - dr1 * ((r1 - r0) / (dr1 - dr0));
            r0 = r1; r1 = r2; dr0 = dr1;
        }
        var s = r1 / radius;
        return [x * s, y * s];
    }

    // Screen and eye-texture extents in tan-angle units, with the optical centre's position.
    function viewports(eye) {
        var toLens = cfg.screenToLens;
        var eyeCentre = (cfg.screen[0] + (eye === 0 ? -cfg.interLens : cfg.interLens)) / 2;
        var fov = cfg.fov[eye];
        return {
            screen: {
                w: cfg.screen[0] / toLens, h: cfg.screen[1] / toLens,
                x: eyeCentre / toLens, y: cfg.yEyeOffset / toLens
            },
            texture: {
                w: Math.tan(fov[0]) + Math.tan(fov[1]), h: Math.tan(fov[2]) + Math.tan(fov[3]),
                x: Math.tan(fov[0]), y: Math.tan(fov[2])
            }
        };
    }

    // Where an eye-texture UV appears on the screen, once the lens has bent it.
    function textureUvToScreenUv(u, v, eye) {
        var vp = viewports(eye);
        var p = distortInverse(u * vp.texture.w - vp.texture.x, v * vp.texture.h - vp.texture.y);
        return [(p[0] + vp.screen.x) / vp.screen.w, (p[1] + vp.screen.y) / vp.screen.h];
    }

    // A grid warping one eye's half of the framebuffer onto its half of the screen. Positions are
    // clip coordinates for the whole screen; UVs index the shared framebuffer, so the eye's half
    // is folded in here.
    function distortionMesh(eye) {
        var pos = [], uv = [], idx = [];
        for (var row = 0; row < MESH; row++) {
            for (var col = 0; col < MESH; col++) {
                var u = col / (MESH - 1), v = row / (MESH - 1);
                var s = textureUvToScreenUv(u, v, eye);
                pos.push(2 * s[0] - 1, 2 * s[1] - 1);
                uv.push(eye === 0 ? u * 0.5 : 0.5 + u * 0.5, v);
            }
        }
        for (row = 0; row < MESH - 1; row++) {
            for (col = 0; col < MESH - 1; col++) {
                var i = row * MESH + col;
                idx.push(i, i + MESH, i + 1, i + 1, i + MESH, i + MESH + 1);
            }
        }
        return { pos: new Float32Array(pos), uv: new Float32Array(uv), idx: new Uint16Array(idx) };
    }

    // ---------------------------------------------------------------- matrices
    // Column-major, as WebGL and WebXR both want.
    function fromQuatPos(q, p) {
        var x = q[0], y = q[1], z = q[2], w = q[3];
        return new Float32Array([
            1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
            p[0], p[1], p[2], 1
        ]);
    }
    // A rigid transform's inverse: transpose the rotation, negate the rotated translation.
    function invertRigid(m) {
        var out = new Float32Array(16);
        out[0] = m[0]; out[1] = m[4]; out[2] = m[8];
        out[4] = m[1]; out[5] = m[5]; out[6] = m[9];
        out[8] = m[2]; out[9] = m[6]; out[10] = m[10];
        out[12] = -(m[0] * m[12] + m[1] * m[13] + m[2] * m[14]);
        out[13] = -(m[4] * m[12] + m[5] * m[13] + m[6] * m[14]);
        out[14] = -(m[8] * m[12] + m[9] * m[13] + m[10] * m[14]);
        out[15] = 1;
        return out;
    }
    function multiply(a, b) {
        var o = new Float32Array(16);
        for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) {
            var s = 0;
            for (var k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
            o[c * 4 + r] = s;
        }
        return o;
    }
    function projection(eye, near, far) {
        var fov = cfg.fov[eye];
        var l = -Math.tan(fov[0]) * near, r = Math.tan(fov[1]) * near;
        var b = -Math.tan(fov[2]) * near, t = Math.tan(fov[3]) * near;
        var o = new Float32Array(16);
        o[0] = 2 * near / (r - l); o[5] = 2 * near / (t - b);
        o[8] = (r + l) / (r - l); o[9] = (t + b) / (t - b);
        o[10] = -(far + near) / (far - near); o[11] = -1;
        o[14] = -2 * far * near / (far - near);
        return o;
    }

    // A plain symmetric frustum for phone view, matching the rig's single camera. Its field of
    // view is vertical, as Unity's is, and the aspect comes from the canvas.
    function monoProjection(near, far) {
        var aspect = screenAspect();
        var t = Math.tan((cfg.monoFov || (60 * DEG)) / 2) * near;
        var r = t * aspect;
        var o = new Float32Array(16);
        o[0] = near / r; o[5] = near / t;
        o[10] = -(far + near) / (far - near); o[11] = -1;
        o[14] = -2 * far * near / (far - near);
        return o;
    }
    // The screen's own shape, from its size in metres: the window's size is not it once the app
    // scales the page onto the screen for a session (the page keeps its windowed layout, so a
    // page that rebuilds its renderer on resize isn't thrown out of its own session).
    function screenAspect() {
        if (cfg.screen && cfg.screen[0] > 0 && cfg.screen[1] > 0) return cfg.screen[0] / cfg.screen[1];
        var w = window.innerWidth || 1, h = window.innerHeight || 1;
        return w / h;
    }

    // ---------------------------------------------------------------- head pose
    var pose = { p: [0, 0, 0], q: [0, 0, 0, 1] };
    window.__afterglowPose = function (px, py, pz, qx, qy, qz, qw) {
        pose.p[0] = px; pose.p[1] = py; pose.p[2] = pz;
        pose.q[0] = qx; pose.q[1] = qy; pose.q[2] = qz; pose.q[3] = qw;
    };

    // ---------------------------------------------------------------- the real room
    // How far the eyes were above the floor ARKit found, for local-floor (a fixed 1.6 m put a
    // seated owner's world at the wrong height), and the room's planes in the session's space,
    // for hit tests.
    var eyeLift = cfg.eyeHeight || 1.6;
    window.__afterglowFloor = function (metres) { eyeLift = metres; };
    var roomPlanes = [];
    // Eleven numbers a plane: centre, orientation (its +y is the normal), and its bounds in its
    // own x and z.
    window.__afterglowPlanes = function (v) {
        var out = [];
        for (var i = 0; i + 11 <= v.length; i += 11)
            out.push({ c: [v[i], v[i + 1], v[i + 2]], q: [v[i + 3], v[i + 4], v[i + 5], v[i + 6]],
                       minX: v[i + 7], maxX: v[i + 8], minZ: v[i + 9], maxZ: v[i + 10] });
        roomPlanes = out;
    };

    // ---------------------------------------------------------------- the exit button
    // A button the app places at the user's feet, in the session's own space, and draws into
    // both eyes over the page, so a session can always be left (owner, 2026-11-08: the pinch
    // and hold to leave was unreliable). The app does the placing and the hit-testing; this
    // only draws it.
    var exitButton = { shown: false, c: [0, 0, 0], q: [0, 0, 0, 1], w: 0.36, h: 0.12, hovered: false };
    window.__afterglowExit = function (cx, cy, cz, qx, qy, qz, qw, w, h, hovered) {
        exitButton.shown = true;
        exitButton.c[0] = cx; exitButton.c[1] = cy; exitButton.c[2] = cz;
        exitButton.q[0] = qx; exitButton.q[1] = qy; exitButton.q[2] = qz; exitButton.q[3] = qw;
        exitButton.w = w; exitButton.h = h; exitButton.hovered = !!hovered;
    };
    function exitPicture(hovered) {
        var c = document.createElement('canvas');
        c.width = 768; c.height = 256;
        var g = c.getContext('2d');
        function round(x, y, w, h, r) {
            g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
            g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
        }
        round(8, 8, 752, 240, 120);
        g.fillStyle = hovered ? 'rgba(70, 20, 60, 0.92)' : 'rgba(20, 16, 34, 0.85)';
        g.fill();
        g.lineWidth = hovered ? 16 : 6;
        g.strokeStyle = hovered ? '#ff4fb8' : 'rgba(255, 255, 255, 0.35)';
        g.stroke();
        g.fillStyle = '#ff5f57';
        g.beginPath(); g.arc(128, 128, 72, 0, Math.PI * 2); g.fill();
        g.strokeStyle = '#ffffff'; g.lineWidth = 18; g.lineCap = 'round';
        g.beginPath(); g.moveTo(100, 100); g.lineTo(156, 156); g.moveTo(156, 100); g.lineTo(100, 156); g.stroke();
        g.fillStyle = '#ffffff';
        g.font = '600 104px -apple-system, Helvetica, sans-serif';
        g.textBaseline = 'middle';
        g.fillText('Exit VR', 236, 134);
        return c;
    }

    // ---------------------------------------------------------------- WebXR surface
    function XRRigidTransform(position, orientation) {
        this.position = position || { x: 0, y: 0, z: 0, w: 1 };
        this.orientation = orientation || { x: 0, y: 0, z: 0, w: 1 };
        this.matrix = fromQuatPos(
            [this.orientation.x, this.orientation.y, this.orientation.z, this.orientation.w],
            [this.position.x, this.position.y, this.position.z]);
        var self = this;
        Object.defineProperty(this, 'inverse', {
            get: function () {
                var t = Object.create(XRRigidTransform.prototype);
                t.matrix = invertRigid(self.matrix);
                t.position = { x: t.matrix[12], y: t.matrix[13], z: t.matrix[14], w: 1 };
                t.orientation = self.orientation;
                return t;
            }
        });
    }

    function XRView(eye, projectionMatrix, transform) {
        this.eye = eye === 0 ? 'left' : eye === 1 ? 'right' : 'none';
        this.projectionMatrix = projectionMatrix;
        this.transform = transform;
        this.recommendedViewportScale = null;
    }
    XRView.prototype.requestViewportScale = function () {};

    function XRReferenceSpace(kind) { this._kind = kind; }
    XRReferenceSpace.prototype.getOffsetReferenceSpace = function (transform) {
        var s = new XRReferenceSpace(this._kind);
        s._offset = transform;
        return s;
    };
    XRReferenceSpace.prototype.addEventListener = function () {};
    XRReferenceSpace.prototype.removeEventListener = function () {};

    function XRWebGLLayer(session, gl) {
        this._session = session;
        this._gl = gl;
        session._attachLayer(this, gl);
        this.antialias = false;
        this.ignoreDepthValues = false;
    }
    Object.defineProperty(XRWebGLLayer.prototype, 'framebuffer', {
        get: function () { return this._session._fbo; }
    });
    Object.defineProperty(XRWebGLLayer.prototype, 'framebufferWidth', {
        get: function () { return this._session._fbWidth; }
    });
    Object.defineProperty(XRWebGLLayer.prototype, 'framebufferHeight', {
        get: function () { return this._session._fbHeight; }
    });
    XRWebGLLayer.prototype.getViewport = function (view) {
        if (cfg.mono)
            return { x: 0, y: 0, width: this._session._fbWidth, height: this._session._fbHeight };
        var half = this._session._fbWidth / 2;
        return { x: view.eye === 'left' ? 0 : half, y: 0, width: half, height: this._session._fbHeight };
    };
    XRWebGLLayer.getNativeFramebufferScaleFactor = function () { return 1.0; };

    function XRSession() {
        this._callbacks = [];
        this._nextHandle = 1;
        this._listeners = {};
        this._ended = false;
        this.renderState = { depthNear: 0.1, depthFar: 1000, baseLayer: null };
        this.environmentBlendMode = 'opaque';
        this.interactionMode = 'world-space';
        this.enabledFeatures = [];
        this.visibilityState = 'visible';
        this.inputSources = [];
        this.domOverlayState = null;
    }
    XRSession.prototype.addEventListener = function (type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    };
    XRSession.prototype.removeEventListener = function (type, fn) {
        var l = this._listeners[type]; if (!l) return;
        var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1);
    };
    XRSession.prototype._emit = function (type, event) {
        event = event || {}; event.type = type; event.session = this;
        var l = (this._listeners[type] || []).slice();
        for (var i = 0; i < l.length; i++) l[i].call(this, event);
        var handler = this['on' + type];
        if (typeof handler === 'function') handler.call(this, event);
    };

    // Rotates a vector by a quaternion, for placing each eye beside the head.
    function rotateVec(q, v) {
        var x = q[0], y = q[1], z = q[2], w = q[3];
        var ix = w * v[0] + y * v[2] - z * v[1];
        var iy = w * v[1] + z * v[0] - x * v[2];
        var iz = w * v[2] + x * v[1] - y * v[0];
        var iw = -x * v[0] - y * v[1] - z * v[2];
        return [
            ix * w + iw * -x + iy * -z - iz * -y,
            iy * w + iw * -y + iz * -x - ix * -z,
            iz * w + iw * -z + ix * -y - iy * -x
        ];
    }

    function XRViewerPose(transform, views) {
        this.transform = transform;
        this.views = views;
        this.emulatedPosition = !cfg.hasPosition;
    }

    function XRFrame(session) {
        this.session = session;
        this.predictedDisplayTime = performance.now();
    }
    XRFrame.prototype.getViewerPose = function (space) {
        this._poseSeen = true;
        var q = pose.q;
        // A floor-relative space puts the origin under the user rather than at the head.
        var lift = space && space._kind === 'local-floor' ? eyeLift : 0;
        var head = new XRRigidTransform(
            { x: pose.p[0], y: pose.p[1] + lift, z: pose.p[2] },
            { x: q[0], y: q[1], z: q[2], w: q[3] });
        var near = this.session.renderState.depthNear, far = this.session.renderState.depthFar;
        // Phone view: one picture from where the head is, no eye separation, so holding the phone
        // in your hand shows the scene rather than a split pair meant for lenses.
        if (cfg.mono)
            return new XRViewerPose(head, [new XRView(-1, monoProjection(near, far), head)]);

        var views = [];
        for (var eye = 0; eye < 2; eye++) {
            var offset = rotateVec(q, [(eye === 0 ? -0.5 : 0.5) * cfg.interLens, 0, 0]);
            var transform = new XRRigidTransform(
                { x: head.position.x + offset[0], y: head.position.y + offset[1], z: head.position.z + offset[2] },
                head.orientation);
            views.push(new XRView(eye, projection(eye, near, far), transform));
        }
        return new XRViewerPose(head, views);
    };
    // Hit tests against the room's planes, for a page placing things on real surfaces.
    function XRRay(origin, direction) {
        if (origin && origin.matrix) {          // the XRRigidTransform form
            var m = origin.matrix;
            this.origin = { x: m[12], y: m[13], z: m[14], w: 1 };
            this.direction = { x: -m[8], y: -m[9], z: -m[10], w: 0 };
        } else {
            var o = origin || {}, d = direction || {};
            var n = norm([d.x === undefined ? 0 : d.x, d.y === undefined ? 0 : d.y, d.z === undefined ? -1 : d.z]);
            this.origin = { x: o.x || 0, y: o.y || 0, z: o.z || 0, w: 1 };
            this.direction = { x: n[0], y: n[1], z: n[2], w: 0 };
        }
    }
    function XRHitTestSource(space, ray) { this._space = space; this._ray = ray || new XRRay(); this._cancelled = false; }
    XRHitTestSource.prototype.cancel = function () { this._cancelled = true; };
    function XRHitTestResult(p, q) { this._p = p; this._q = q; }
    XRHitTestResult.prototype.getPose = function (base) { return intoBase(this._p, this._q, base); };
    // Where a space is, in the app's space (the session's "local").
    function spaceInLocal(space) {
        if (!space || space._kind === 'viewer') return { p: pose.p, q: pose.q };
        if (space._kind === 'local') return { p: [0, 0, 0], q: [0, 0, 0, 1] };
        if (space._kind === 'local-floor') return { p: [0, -eyeLift, 0], q: [0, 0, 0, 1] };
        var hand = handSpacePose(space, { _kind: 'local' });
        if (!hand) return null;
        var t = hand.transform;
        return { p: [t.position.x, t.position.y, t.position.z], q: [t.orientation.x, t.orientation.y, t.orientation.z, t.orientation.w] };
    }
    XRFrame.prototype.getHitTestResults = function (source) {
        if (!source || source._cancelled) return [];
        var from = spaceInLocal(source._space);
        if (!from) return [];
        var r = source._ray;
        var local = rotateVec(from.q, [r.origin.x, r.origin.y, r.origin.z]);
        var o = [from.p[0] + local[0], from.p[1] + local[1], from.p[2] + local[2]];
        var d = rotateVec(from.q, [r.direction.x, r.direction.y, r.direction.z]);
        var hits = [];
        for (var i = 0; i < roomPlanes.length; i++) {
            var pl = roomPlanes[i];
            var n = rotateVec(pl.q, [0, 1, 0]);
            var facing = d[0] * n[0] + d[1] * n[1] + d[2] * n[2];
            if (Math.abs(facing) < 1e-4) continue;
            var to = sub(pl.c, o);
            var t = (to[0] * n[0] + to[1] * n[1] + to[2] * n[2]) / facing;
            if (t <= 0) continue;
            var h = [o[0] + d[0] * t, o[1] + d[1] * t, o[2] + d[2] * t];
            var inPlane = rotateVec(conj(pl.q), sub(h, pl.c));
            if (inPlane[0] < pl.minX || inPlane[0] > pl.maxX || inPlane[2] < pl.minZ || inPlane[2] > pl.maxZ) continue;
            hits.push({ t: t, result: new XRHitTestResult(h, pl.q) });
        }
        hits.sort(function (a, b) { return a.t - b.t; });
        return hits.map(function (x) { return x.result; });
    };
    XRFrame.prototype.getHitTestResultsForTransientInput = function () { return []; };
    XRSession.prototype.requestHitTestSource = function (options) {
        if (!options || !options.space) return Promise.reject(new TypeError('requestHitTestSource needs a space'));
        return Promise.resolve(new XRHitTestSource(options.space, options.offsetRay));
    };
    XRSession.prototype.requestHitTestSourceForTransientInput = function () {
        return Promise.reject(new DOMException('Afterglow has no transient hit tests', 'NotSupportedError'));
    };

    // The viewer's own spaces have the head's pose: the gaze ray starts at the head. A hand's
    // spaces (its ray, its grip, its joints) have poses while the app tracks that hand. Anything
    // else returns null, which is what a page should see for a space this cannot locate.
    XRFrame.prototype.getPose = function (space, base) {
        if (!space) return null;
        if (space._kind === 'ray' || space._kind === 'grip' || space._kind === 'joint')
            return handSpacePose(space, base);
        if (space._kind !== 'viewer' && space._kind !== 'local' && space._kind !== 'local-floor')
            return null;
        var viewer = this.getViewerPose(base);
        return viewer ? { transform: viewer.transform, emulatedPosition: viewer.emulatedPosition } : null;
    };
    XRFrame.prototype.getJointPose = function (joint, base) {
        if (!joint || joint._kind !== 'joint') return null;
        return handSpacePose(joint, base);
    };
    // The batch forms: every pose as a 4x4 matrix into `out`, 16 floats each, and the radii.
    // True only when every space had a pose, as the spec asks.
    XRFrame.prototype.fillPoses = function (spaces, base, out) {
        var all = true, i = 0;
        for (var it = spaces[Symbol.iterator] ? spaces[Symbol.iterator]() : spaces.values(), r = it.next(); !r.done; r = it.next(), i++) {
            var p = r.value._kind === 'joint' ? this.getJointPose(r.value, base) : this.getPose(r.value, base);
            if (!p) { all = false; for (var k = 0; k < 16; k++) out[i * 16 + k] = NaN; continue; }
            for (var k2 = 0; k2 < 16; k2++) out[i * 16 + k2] = p.transform.matrix[k2];
        }
        return all;
    };
    XRFrame.prototype.fillJointRadii = function (spaces, out) {
        var all = true, i = 0;
        for (var it = spaces[Symbol.iterator] ? spaces[Symbol.iterator]() : spaces.values(), r = it.next(); !r.done; r = it.next(), i++) {
            var p = r.value._kind === 'joint' ? this.getJointPose(r.value, null) : null;
            if (!p) { all = false; out[i] = NaN; continue; }
            out[i] = p.radius;
        }
        return all;
    };

    function XRInputSource() {
        this.handedness = 'none';
        this.targetRayMode = 'gaze';
        this.targetRaySpace = new XRReferenceSpace('viewer');
        this.gripSpace = null;
        this.profiles = [];
        this.gamepad = null;
        this.hand = null;
    }

    // ---------------------------------------------------------------- hands
    // The app's tracked hands as WebXR Hand Input: an input source per hand, with the 25 joint
    // spaces the spec names, posed each frame from the 21 landmarks the app pushes
    // (__afterglowHands) in the same space as the head pose. The landmarks have no metacarpals,
    // so those sit midway between the wrist and the knuckle. A pinch on a hand is that source's
    // select; the gaze source stays first, for taps.
    var JOINT_NAMES = [
        'wrist',
        'thumb-metacarpal', 'thumb-phalanx-proximal', 'thumb-phalanx-distal', 'thumb-tip',
        'index-finger-metacarpal', 'index-finger-phalanx-proximal', 'index-finger-phalanx-intermediate', 'index-finger-phalanx-distal', 'index-finger-tip',
        'middle-finger-metacarpal', 'middle-finger-phalanx-proximal', 'middle-finger-phalanx-intermediate', 'middle-finger-phalanx-distal', 'middle-finger-tip',
        'ring-finger-metacarpal', 'ring-finger-phalanx-proximal', 'ring-finger-phalanx-intermediate', 'ring-finger-phalanx-distal', 'ring-finger-tip',
        'pinky-finger-metacarpal', 'pinky-finger-phalanx-proximal', 'pinky-finger-phalanx-intermediate', 'pinky-finger-phalanx-distal', 'pinky-finger-tip'
    ];
    // The landmark each joint comes from (MediaPipe's order); a negative value is a metacarpal,
    // midway between the wrist and the knuckle that follows.
    var JOINT_FROM = [0, 1, 2, 3, 4, -5, 5, 6, 7, 8, -9, 9, 10, 11, 12, -13, 13, 14, 15, 16, -17, 17, 18, 19, 20];
    // The joint each one points toward (the next one out along its finger; the tips point on
    // from the joint before), for the joint's orientation.
    var JOINT_NEXT = [10, 2, 3, 4, 4, 6, 7, 8, 9, 9, 11, 12, 13, 14, 14, 16, 17, 18, 19, 19, 21, 22, 23, 24, 24];
    var JOINT_RADIUS = [0.02, 0.012, 0.011, 0.009, 0.007, 0.012, 0.01, 0.009, 0.008, 0.007, 0.012, 0.01, 0.009, 0.008, 0.007,
                        0.011, 0.009, 0.008, 0.007, 0.006, 0.01, 0.008, 0.007, 0.006, 0.006];

    function XRJointSpace(name, source) { this.jointName = name; this._kind = 'joint'; this._source = source; }
    function XRHandSpace(kind, source) { this._kind = kind; this._source = source; }
    function XRHand(source) {
        var spaces = new Map();
        for (var i = 0; i < JOINT_NAMES.length; i++) spaces.set(JOINT_NAMES[i], new XRJointSpace(JOINT_NAMES[i], source));
        this._spaces = spaces;
        this.size = spaces.size;
    }
    XRHand.prototype.get = function (name) { return this._spaces.get(name); };
    XRHand.prototype.has = function (name) { return this._spaces.has(name); };
    XRHand.prototype.keys = function () { return this._spaces.keys(); };
    XRHand.prototype.values = function () { return this._spaces.values(); };
    XRHand.prototype.entries = function () { return this._spaces.entries(); };
    XRHand.prototype.forEach = function (cb, thisArg) { this._spaces.forEach(cb, thisArg); };
    XRHand.prototype[Symbol.iterator] = function () { return this._spaces.entries(); };

    // One Euro filters: steady when still, quick when moving, so a pointer doesn't shake at rest
    // and doesn't lag a sweep. minCutoff is the smoothing at rest in Hz, beta how fast it lets go
    // with speed.
    function OneEuro(minCutoff, beta) {
        this.minCutoff = minCutoff; this.beta = beta; this.dCutoff = 1.0;
        this.x = null; this.dx = 0; this.t = 0;
    }
    OneEuro.prototype.alpha = function (cutoff, dt) { var tau = 1 / (2 * Math.PI * cutoff); return 1 / (1 + tau / dt); };
    OneEuro.prototype.filter = function (x, t) {
        if (this.x === null) { this.x = x; this.t = t; return x; }
        var dt = Math.max(1e-3, t - this.t);
        this.t = t;
        var dx = (x - this.x) / dt;
        var ad = this.alpha(this.dCutoff, dt);
        this.dx = ad * dx + (1 - ad) * this.dx;
        var cutoff = this.minCutoff + this.beta * Math.abs(this.dx);
        var a = this.alpha(cutoff, dt);
        this.x = a * x + (1 - a) * this.x;
        return this.x;
    };
    OneEuro.prototype.reset = function () { this.x = null; this.dx = 0; };
    function Vec3Euro(minCutoff, beta) { this.f = [new OneEuro(minCutoff, beta), new OneEuro(minCutoff, beta), new OneEuro(minCutoff, beta)]; }
    Vec3Euro.prototype.filter = function (v, t) { return [this.f[0].filter(v[0], t), this.f[1].filter(v[1], t), this.f[2].filter(v[2], t)]; };
    Vec3Euro.prototype.reset = function () { this.f[0].reset(); this.f[1].reset(); this.f[2].reset(); };

    // The joints are smoothed lightly (hands still look live); the pointing ray harder, since
    // a wand is held on something for a while.
    var JOINT_SMOOTHING = { minCutoff: 1.5, beta: 0.8 };
    var RAY_SMOOTHING = { minCutoff: 0.6, beta: 0.4 };
    // Where the shoulder is from the head, in the head's frame: down and to the hand's side. The
    // ray runs from there through the palm, which moves with the arm rather than the fingers.
    var SHOULDER = { down: 0.22, aside: 0.17, back: 0.05 };

    function handSource(handedness) {
        var s = new XRInputSource();
        s.handedness = handedness;
        s.targetRayMode = 'tracked-pointer';
        s.targetRaySpace = new XRHandSpace('ray', s);
        s.gripSpace = new XRHandSpace('grip', s);
        s.profiles = ['generic-hand-select', 'generic-hand'];
        s.hand = new XRHand(s);
        s._joints = new Float32Array(63);
        s._raw = new Float32Array(63);
        s._jointFilters = [];
        for (var i = 0; i < 21; i++) s._jointFilters.push(new Vec3Euro(JOINT_SMOOTHING.minCutoff, JOINT_SMOOTHING.beta));
        s._rayOrigin = new Vec3Euro(RAY_SMOOTHING.minCutoff, RAY_SMOOTHING.beta);
        s._rayDir = new Vec3Euro(RAY_SMOOTHING.minCutoff, RAY_SMOOTHING.beta);
        s._ray = null;
        s._present = false;
        s._pinching = false;
        s._lastSent = 0;
        return s;
    }
    // A source the app stops sending stays for this long, at its last pose, so a hand missed
    // for a frame or two doesn't come and go for the page.
    var SOURCE_GRACE_SECONDS = 0.35;
    function resetSource(s) {
        for (var i = 0; i < s._jointFilters.length; i++) s._jointFilters[i].reset();
        s._rayOrigin.reset(); s._rayDir.reset(); s._ray = null;
    }
    // The pointing ray for a hand, from the raw landmarks of this frame: its origin the palm,
    // its direction from the shoulder through the palm, both smoothed. Worked out once per
    // frame when the hands arrive, so every getPose in the frame agrees.
    function updateRay(s, t) {
        var w = raw(s, 0), k5 = raw(s, 5), k9 = raw(s, 9), k13 = raw(s, 13), k17 = raw(s, 17);
        var palm = [(w[0] + k5[0] + k9[0] + k13[0] + k17[0]) / 5, (w[1] + k5[1] + k9[1] + k13[1] + k17[1]) / 5, (w[2] + k5[2] + k9[2] + k13[2] + k17[2]) / 5];
        var side = s.handedness === 'right' ? SHOULDER.aside : -SHOULDER.aside;
        var shoulder = rotateVec(pose.q, [side, -SHOULDER.down, SHOULDER.back]);
        shoulder = [pose.p[0] + shoulder[0], pose.p[1] + shoulder[1], pose.p[2] + shoulder[2]];
        var dir = norm(sub(palm, shoulder));
        var origin = s._rayOrigin.filter(palm, t);
        var smoothDir = norm(s._rayDir.filter(dir, t));
        s._ray = { origin: origin, dir: smoothDir, palm: palm };
    }
    function raw(s, i) { return [s._raw[i * 3], s._raw[i * 3 + 1], s._raw[i * 3 + 2]]; }
    var handSources = { left: null, right: null };

    function landmark(src, i) { return [src._joints[i * 3], src._joints[i * 3 + 1], src._joints[i * 3 + 2]]; }
    function jointPosition(src, j) {
        var from = JOINT_FROM[j];
        if (from >= 0) return landmark(src, from);
        var w = landmark(src, 0), k = landmark(src, -from);
        return [(w[0] + k[0]) / 2, (w[1] + k[1]) / 2, (w[2] + k[2]) / 2];
    }
    function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
    function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
    function norm(v) { var l = Math.hypot(v[0], v[1], v[2]) || 1; return [v[0] / l, v[1] / l, v[2] / l]; }
    // A quaternion whose -Z is `forward` and whose +Y is as near `up` as it can be.
    function quatLook(forward, up) {
        var z = norm([-forward[0], -forward[1], -forward[2]]);
        var x = norm(cross(up, z));
        if (!isFinite(x[0]) || (x[0] === 0 && x[1] === 0 && x[2] === 0)) x = norm(cross([0, 1, 0], z));
        var y = cross(z, x);
        var t = x[0] + y[1] + z[2], q;
        if (t > 0) { var r = Math.sqrt(t + 1) * 2; q = [(y[2] - z[1]) / r, (z[0] - x[2]) / r, (x[1] - y[0]) / r, 0.25 * r]; }
        else if (x[0] > y[1] && x[0] > z[2]) { var r1 = Math.sqrt(1 + x[0] - y[1] - z[2]) * 2; q = [0.25 * r1, (y[0] + x[1]) / r1, (z[0] + x[2]) / r1, (y[2] - z[1]) / r1]; }
        else if (y[1] > z[2]) { var r2 = Math.sqrt(1 + y[1] - x[0] - z[2]) * 2; q = [(y[0] + x[1]) / r2, 0.25 * r2, (z[1] + y[2]) / r2, (z[0] - x[2]) / r2]; }
        else { var r3 = Math.sqrt(1 + z[2] - x[0] - y[1]) * 2; q = [(z[0] + x[2]) / r3, (z[1] + y[2]) / r3, 0.25 * r3, (x[1] - y[0]) / r3]; }
        return q;
    }
    function palmNormal(src) {
        // Out of the back of the hand: wrist to index knuckle crossed with wrist to pinky knuckle,
        // the other way round for the other hand.
        var w = landmark(src, 0), n = cross(sub(landmark(src, 5), w), sub(landmark(src, 17), w));
        return norm(src.handedness === 'right' ? n : [-n[0], -n[1], -n[2]]);
    }
    function conj(q) { return [-q[0], -q[1], -q[2], q[3]]; }
    // A pose given in the app's space, moved into `base`: local as is, local-floor lifted as the
    // viewer pose is, viewer relative to the head.
    function intoBase(p, q, base) {
        var kind = base ? base._kind : 'local';
        if (kind === 'local-floor') p = [p[0], p[1] + eyeLift, p[2]];
        if (kind === 'viewer') {
            var hq = pose.q, inv = conj(hq);
            p = rotateVec(inv, sub(p, pose.p));
            q = mulQuat(inv, q);
        }
        return { transform: new XRRigidTransform({ x: p[0], y: p[1], z: p[2], w: 1 }, { x: q[0], y: q[1], z: q[2], w: q[3] }), emulatedPosition: false };
    }
    function mulQuat(a, b) {
        return [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
                a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
                a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
                a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
    }
    function handSpacePose(space, base) {
        var src = space._source;
        if (!src || !src._present) return null;
        var up = palmNormal(src);
        if (space._kind === 'joint') {
            var j = JOINT_NAMES.indexOf(space.jointName);
            if (j < 0) return null;
            var p = jointPosition(src, j), toward = jointPosition(src, JOINT_NEXT[j]);
            var dir = JOINT_FROM[j] === 4 || JOINT_FROM[j] === 8 || JOINT_FROM[j] === 12 || JOINT_FROM[j] === 16 || JOINT_FROM[j] === 20
                ? sub(p, toward) : sub(toward, p);
            var out = intoBase(p, quatLook(dir, up), base);
            out.radius = JOINT_RADIUS[j];
            return out;
        }
        var w = landmark(src, 0), k5 = landmark(src, 5), k9 = landmark(src, 9), k13 = landmark(src, 13), k17 = landmark(src, 17);
        var palm = [(w[0] + k5[0] + k9[0] + k13[0] + k17[0]) / 5, (w[1] + k5[1] + k9[1] + k13[1] + k17[1]) / 5, (w[2] + k5[2] + k9[2] + k13[2] + k17[2]) / 5];
        if (space._kind === 'grip')
            return intoBase(palm, quatLook(sub(k9, w), up), base);
        // The pointing ray (updateRay): from the palm, the way the shoulder-to-palm line goes,
        // smoothed; rolled with the world's up rather than the palm's, which wavers.
        var ray = src._ray;
        if (!ray) return null;
        return intoBase(ray.origin, quatLook(ray.dir, [0, 1, 0]), base);
    }

    // The app's hands, each frame: [count, then per hand handedness (0 left, 1 right), pinching
    // (0/1) and 21 x (x, y, z)]. Sources come and go with the hands; a pinch that closes is a
    // selectstart on that hand, one that opens a select then a selectend.
    window.__afterglowHands = function (a) {
        if (!active || active._ended || !a) return;
        var count = a[0] | 0, seen = { left: false, right: false }, added = [], removed = [];
        for (var h = 0; h < count; h++) {
            var at = 1 + h * 65;
            var handed = a[at] > 0.5 ? 'right' : 'left';
            if (seen[handed]) continue;
            seen[handed] = true;
            var src = handSources[handed] || (handSources[handed] = handSource(handed));
            if (!src._present) { src._present = true; added.push(src); resetSource(src); }
            var now = performance.now() / 1000;
            for (var i = 0; i < 63; i++) src._raw[i] = a[at + 2 + i];
            for (var j = 0; j < 21; j++) {
                var sm = src._jointFilters[j].filter(raw(src, j), now);
                src._joints[j * 3] = sm[0]; src._joints[j * 3 + 1] = sm[1]; src._joints[j * 3 + 2] = sm[2];
            }
            updateRay(src, now);
            src._pinchNow = a[at + 1] > 0.5;
        }
        var tNow = performance.now() / 1000;
        for (var side in handSources) {
            var s = handSources[side];
            if (!s) continue;
            if (seen[side]) { s._lastSent = tNow; continue; }
            if (s._present && tNow - s._lastSent > SOURCE_GRACE_SECONDS) { s._present = false; s._pinchNow = false; removed.push(s); }
        }
        if (added.length || removed.length) {
            var sources = [active.inputSources[0] || new XRInputSource()];
            if (handSources.left && handSources.left._present) sources.push(handSources.left);
            if (handSources.right && handSources.right._present) sources.push(handSources.right);
            active.inputSources = sources;
            active._emit('inputsourceschange', { session: active, added: added, removed: removed });
            console.log('[Afterglow] hands: ' + (sources.length - 1) + ' input source(s)' + (added.length ? ', added ' + added.map(function (x) { return x.handedness; }).join('+') : '') + (removed.length ? ', removed ' + removed.map(function (x) { return x.handedness; }).join('+') : ''));
        }
        for (var side2 in handSources) {
            var hs = handSources[side2];
            if (!hs) continue;
            if (hs._pinchNow && !hs._pinching) {
                hs._pinching = true;
                console.log('[Afterglow] hands: ' + hs.handedness + ' selectstart');
                active._emit('selectstart', { inputSource: hs, frame: new XRFrame(active) });
            } else if (!hs._pinchNow && hs._pinching) {
                hs._pinching = false;
                console.log('[Afterglow] hands: ' + hs.handedness + ' select, selectend');
                active._emit('select', { inputSource: hs, frame: new XRFrame(active) });
                active._emit('selectend', { inputSource: hs, frame: new XRFrame(active) });
            }
        }
    };

    // ---------------------------------------------------------------- the render target
    // The page draws both eyes into one offscreen framebuffer; the distortion pass then warps each
    // half onto its side of the screen. Drawing straight to the canvas would skip the lenses'
    // correction, which on a Cardboard viewer is the difference between a usable image and a
    // pincushioned one.
    function createTarget(gl, w, h) {
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

        var depth = gl.createRenderbuffer();
        gl.bindRenderbuffer(gl.RENDERBUFFER, depth);
        gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, w, h);

        var fbo = gl.createFramebuffer();
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
        gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depth);
        var ok = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        if (!ok) { console.error('[Afterglow] eye framebuffer incomplete'); return null; }
        return { fbo: fbo, tex: tex, depth: depth };
    }

    var VERT = 'attribute vec2 aPos; attribute vec2 aUv; varying vec2 vUv;' +
               'void main() { vUv = aUv; gl_Position = vec4(aPos, 0.0, 1.0); }';
    var FRAG = 'precision mediump float; varying vec2 vUv; uniform sampler2D uTex;' +
               'void main() { gl_FragColor = texture2D(uTex, vUv); }';

    function compile(gl, type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
            console.error('[Afterglow] shader: ' + gl.getShaderInfoLog(s));
        return s;
    }

    // Vertex array objects keep the distortion meshes' attribute state (and their index buffer,
    // which in GL belongs to the vertex array) apart from the page's. WebGL2 has them built in,
    // WebGL1 through an extension every iPhone offers.
    function vertexArrays(gl) {
        if (window.WebGL2RenderingContext && gl instanceof WebGL2RenderingContext)
            return { create: function () { return gl.createVertexArray(); },
                     bind: function (v) { gl.bindVertexArray(v); },
                     binding: gl.VERTEX_ARRAY_BINDING };
        var ext = gl.getExtension('OES_vertex_array_object');
        if (!ext) return null;
        return { create: function () { return ext.createVertexArrayOES(); },
                 bind: function (v) { ext.bindVertexArrayOES(v); },
                 binding: ext.VERTEX_ARRAY_BINDING_OES };
    }

    // The GL state the shim touches, taken before it draws and put back after. three.js and its
    // kind remember the state they set and skip a call they think redundant, so a program,
    // buffer, texture or vertex array changed behind their back is what they draw with next
    // frame -- the page's scene then goes wrong from the second frame on, with nothing in its
    // own code to blame.
    function saveState(gl, vao) {
        var s = {
            fbo: gl.getParameter(gl.FRAMEBUFFER_BINDING),
            program: gl.getParameter(gl.CURRENT_PROGRAM),
            vao: vao ? gl.getParameter(vao.binding) : null,
            arrayBuffer: gl.getParameter(gl.ARRAY_BUFFER_BINDING),
            renderbuffer: gl.getParameter(gl.RENDERBUFFER_BINDING),
            activeTexture: gl.getParameter(gl.ACTIVE_TEXTURE),
            viewport: gl.getParameter(gl.VIEWPORT),
            clearColor: gl.getParameter(gl.COLOR_CLEAR_VALUE),
            depth: gl.isEnabled(gl.DEPTH_TEST),
            cull: gl.isEnabled(gl.CULL_FACE),
            blend: gl.isEnabled(gl.BLEND),
            scissor: gl.isEnabled(gl.SCISSOR_TEST)
        };
        gl.activeTexture(gl.TEXTURE0);
        s.texture0 = gl.getParameter(gl.TEXTURE_BINDING_2D);
        return s;
    }
    function restoreState(gl, vao, s) {
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, s.texture0);
        gl.activeTexture(s.activeTexture);
        if (vao) vao.bind(s.vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, s.arrayBuffer);
        gl.bindRenderbuffer(gl.RENDERBUFFER, s.renderbuffer);
        gl.useProgram(s.program);
        gl.bindFramebuffer(gl.FRAMEBUFFER, s.fbo);
        gl.viewport(s.viewport[0], s.viewport[1], s.viewport[2], s.viewport[3]);
        gl.clearColor(s.clearColor[0], s.clearColor[1], s.clearColor[2], s.clearColor[3]);
        (s.depth ? gl.enable : gl.disable).call(gl, gl.DEPTH_TEST);
        (s.cull ? gl.enable : gl.disable).call(gl, gl.CULL_FACE);
        (s.blend ? gl.enable : gl.disable).call(gl, gl.BLEND);
        (s.scissor ? gl.enable : gl.disable).call(gl, gl.SCISSOR_TEST);
    }

    function createDistortion(gl) {
        var p = gl.createProgram();
        gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, VERT));
        gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, FRAG));
        gl.linkProgram(p);
        if (!gl.getProgramParameter(p, gl.LINK_STATUS))
            console.error('[Afterglow] program: ' + gl.getProgramInfoLog(p));
        var d = {
            program: p,
            aPos: gl.getAttribLocation(p, 'aPos'),
            aUv: gl.getAttribLocation(p, 'aUv'),
            uTex: gl.getUniformLocation(p, 'uTex'),
            vao: vertexArrays(gl),
            eyes: []
        };
        function buffer(target, data) {
            var b = gl.createBuffer();
            gl.bindBuffer(target, b);
            gl.bufferData(target, data, gl.STATIC_DRAW);
            return b;
        }
        // A mesh: its buffers and, where there are vertex arrays, one holding its attributes.
        function mesh(posData, uvData, idxData) {
            var m = { pos: null, uv: null, idx: null, count: idxData ? idxData.length : 4, array: null };
            if (d.vao) { m.array = d.vao.create(); d.vao.bind(m.array); }
            m.pos = buffer(gl.ARRAY_BUFFER, posData);
            if (d.vao) { gl.enableVertexAttribArray(d.aPos); gl.vertexAttribPointer(d.aPos, 2, gl.FLOAT, false, 0, 0); }
            m.uv = buffer(gl.ARRAY_BUFFER, uvData);
            if (d.vao) { gl.enableVertexAttribArray(d.aUv); gl.vertexAttribPointer(d.aUv, 2, gl.FLOAT, false, 0, 0); }
            if (idxData) m.idx = buffer(gl.ELEMENT_ARRAY_BUFFER, idxData);
            if (d.vao) d.vao.bind(null);
            return m;
        }
        // Phone view draws through this instead: the framebuffer straight onto the screen, with
        // no warp, because there is no lens in front of it.
        d.flat = mesh(new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), new Float32Array([0,0, 1,0, 0,1, 1,1]), null);
        for (var eye = 0; eye < 2; eye++) {
            var m = distortionMesh(eye);
            d.eyes.push(mesh(m.pos, m.uv, m.idx));
        }
        d.exit = createExit(gl, d.vao);
        return d;
    }

    var EXIT_VERT = 'attribute vec2 aPos; attribute vec2 aUv; uniform mat4 uMvp; varying vec2 vUv;' +
                    'void main() { vUv = aUv; gl_Position = uMvp * vec4(aPos, 0.0, 1.0); }';
    var EXIT_FRAG = 'precision mediump float; varying vec2 vUv; uniform sampler2D uTex;' +
                    'void main() { gl_FragColor = texture2D(uTex, vUv); }';
    // The exit button's program, unit quad and its two pictures (plain and hovered), made once.
    function createExit(gl, vao) {
        var p = gl.createProgram();
        gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, EXIT_VERT));
        gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, EXIT_FRAG));
        gl.linkProgram(p);
        if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { console.error('[Afterglow] exit program: ' + gl.getProgramInfoLog(p)); return null; }
        var e = { program: p, aPos: gl.getAttribLocation(p, 'aPos'), aUv: gl.getAttribLocation(p, 'aUv'),
                  uMvp: gl.getUniformLocation(p, 'uMvp'), uTex: gl.getUniformLocation(p, 'uTex'), array: null, textures: [] };
        if (vao) { e.array = vao.create(); vao.bind(e.array); }
        e.pos = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, e.pos);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, 0.5]), gl.STATIC_DRAW);
        if (vao) { gl.enableVertexAttribArray(e.aPos); gl.vertexAttribPointer(e.aPos, 2, gl.FLOAT, false, 0, 0); }
        e.uv = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, e.uv);
        // The canvas's first row is its top: the quad's top corners take v = 0.
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 1, 1, 1, 0, 0, 1, 0]), gl.STATIC_DRAW);
        if (vao) { gl.enableVertexAttribArray(e.aUv); gl.vertexAttribPointer(e.aUv, 2, gl.FLOAT, false, 0, 0); vao.bind(null); }
        var flip = gl.getParameter(gl.UNPACK_FLIP_Y_WEBGL), premultiply = gl.getParameter(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
        for (var hovered = 0; hovered < 2; hovered++) {
            var t = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, t);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, exitPicture(hovered === 1));
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            e.textures.push(t);
        }
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, flip);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, premultiply);
        return e;
    }

    // Binds a mesh for drawing: its vertex array, or its attributes one by one without one.
    function bindMesh(gl, d, m) {
        if (d.vao) { d.vao.bind(m.array); return; }
        gl.bindBuffer(gl.ARRAY_BUFFER, m.pos);
        gl.enableVertexAttribArray(d.aPos);
        gl.vertexAttribPointer(d.aPos, 2, gl.FLOAT, false, 0, 0);
        gl.bindBuffer(gl.ARRAY_BUFFER, m.uv);
        gl.enableVertexAttribArray(d.aUv);
        gl.vertexAttribPointer(d.aUv, 2, gl.FLOAT, false, 0, 0);
        if (m.idx) gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, m.idx);
    }

    // ---------------------------------------------------------------- session lifecycle
    XRSession.prototype._attachLayer = function (layer, gl) {
        this._gl = gl;
        console.log('[Afterglow] layer attached: canvas ' + gl.canvas.width + 'x' + gl.canvas.height + ' css ' +
            gl.canvas.clientWidth + 'x' + gl.canvas.clientHeight + ', ' + (gl instanceof WebGL2RenderingContext ? 'webgl2' : 'webgl'));
        var dpr = window.devicePixelRatio || 1;
        var canvas = gl.canvas;
        // The eye buffer is the screen's own pixels (times the app's render scale), not the
        // window times the pixel ratio: the window is 1024x768 at three pixels per point and
        // is then stretched onto the screen, which on a phone made for nearly twice the pixels
        // the screen can show, drawn and warped every frame for nothing.
        var scale = (cfg.renderScale > 0 ? cfg.renderScale : 100) / 100;
        var px = cfg.screenPixels && cfg.screenPixels[0] > 0 ? cfg.screenPixels : null;
        var w = px ? Math.max(2, Math.round(px[0] * scale)) : Math.max(2, Math.floor(window.innerWidth * dpr));
        var h = px ? Math.max(2, Math.round(px[1] * scale)) : Math.max(2, Math.floor(window.innerHeight * dpr));
        // The canvas's own size and style come back when the session ends, so the page is as it
        // was: a canvas left fixed over the whole page at the top z-index would cover its
        // controls and the app's own marks.
        this._canvasWas = { width: canvas.width, height: canvas.height, style: canvas.getAttribute('style') };
        canvas.width = w;
        canvas.height = h;
        canvas.style.position = 'fixed';
        canvas.style.left = '0';
        canvas.style.top = '0';
        canvas.style.width = '100%';
        canvas.style.height = '100%';
        canvas.style.zIndex = '2147483647';
        // Only the layer shows during an immersive session, as on a headset, where the page's
        // other elements are simply not there. A player's canvas usually sits inside a container
        // that is its own stacking context, so a toolbar outside it would draw over the layer
        // whatever its z-index; the canvas moves to the end of the body for the session and goes
        // back where it was when the session ends.
        this._canvasHome = { parent: canvas.parentNode, next: canvas.nextSibling };
        if (canvas.parentNode !== document.body || canvas.nextSibling) {
            document.body.appendChild(canvas);
            console.log('[Afterglow] layer canvas moved to the end of the body for the session');
        }
        // AR: only the layer over the room. The page and whatever it set behind the canvas go
        // transparent until the session ends.
        if (this._ar) {
            var attrs = gl.getContextAttributes ? gl.getContextAttributes() : null;
            if (attrs && attrs.alpha === false) console.warn('[Afterglow] AR: the page made its context without alpha, so the room cannot show through');
            var hidden = [];
            for (var child = document.body.firstElementChild; child; child = child.nextElementSibling) {
                if (child === canvas || child.contains(canvas)) continue;
                hidden.push({ el: child, was: child.style.visibility });
                child.style.visibility = 'hidden';
            }
            this._arWas = { hidden: hidden, html: document.documentElement.style.background, body: document.body.style.background };
            document.documentElement.style.background = 'transparent';
            document.body.style.background = 'transparent';
        }
        this._fbWidth = w;
        this._fbHeight = h;

        // Made with the page's GL state put back afterwards: three.js is in the middle of its own
        // setup when it makes the layer, with its own vertex array and textures bound.
        var vao = vertexArrays(gl);
        var saved = saveState(gl, vao);
        var target = createTarget(gl, w, h);
        if (target) { this._fbo = target.fbo; this._tex = target.tex; this._depth = target.depth; }
        this._distort = createDistortion(gl);
        restoreState(gl, vao, saved);
        this.renderState.baseLayer = layer;
        console.log('[Afterglow] eye buffer ' + w + 'x' + h + (px ? ' (screen pixels' + (scale !== 1 ? ' x ' + scale.toFixed(2) : '') + ')' : ' (window x pixel ratio)') +
            (target ? ' ready' : ' FAILED') + ', distortion ' + (this._distort ? 'ready' : 'missing'));
    };

    XRSession.prototype.updateRenderState = function (state) {
        for (var key in state) if (Object.prototype.hasOwnProperty.call(state, key))
            this.renderState[key] = state[key];
    };

    XRSession.prototype.requestReferenceSpace = function (type) {
        if (type === 'viewer' || type === 'local' || type === 'local-floor')
            return Promise.resolve(new XRReferenceSpace(type));
        // Anything else -- bounded-floor, unbounded -- this cannot honestly provide.
        return Promise.reject(new Error('Afterglow has no "' + type + '" reference space'));
    };

    XRSession.prototype.requestAnimationFrame = function (cb) {
        var handle = this._nextHandle++;
        this._callbacks.push({ handle: handle, cb: cb });
        this._schedule();
        return handle;
    };
    XRSession.prototype.cancelAnimationFrame = function (handle) {
        for (var i = 0; i < this._callbacks.length; i++)
            if (this._callbacks[i].handle === handle) { this._callbacks.splice(i, 1); return; }
    };
    XRSession.prototype._schedule = function () {
        if (this._pending || this._ended) return;
        this._pending = true;
        var self = this;
        window.requestAnimationFrame(function (t) { self._onFrame(t); });
    };
    XRSession.prototype._onFrame = function (time) {
        this._pending = false;
        if (this._ended) return;
        // Taken before the callbacks run, so frames they ask for go in the next batch.
        var due = this._callbacks;
        this._callbacks = [];
        var gl = this._gl;
        if (gl && this._fbo) gl.bindFramebuffer(gl.FRAMEBUFFER, this._fbo);
        var frame = new XRFrame(this);
        for (var i = 0; i < due.length; i++) {
            try { due[i].cb(time, frame); }
            catch (e) { console.error('[Afterglow] frame callback: ' + (e && e.message) + ' ' + (e && e.stack ? String(e.stack).split('\n').slice(0, 3).join(' | ') : '')); }
        }
        this._frames = (this._frames || 0) + 1;
        // An honest frame rate: what the page actually drew, for the log and the start page.
        var nowMs = performance.now();
        if (!this._rateStart) { this._rateStart = nowMs; this._sessionStart = nowMs; this._rateFrames = 0; }
        this._rateFrames++;
        if (nowMs - this._rateStart >= 5000) {
            console.log('[Afterglow] session drawing ' + (this._rateFrames * 1000 / (nowMs - this._rateStart)).toFixed(1) + ' frames a second');
            this._rateStart = nowMs;
            this._rateFrames = 0;
        }
        if (gl && this._fbo) { this._drawExit(); this._composite(); }
        // The first frames, and then one in a hundred, say whether the page is drawing at all.
        if (this._frames <= 3 || this._frames % 100 === 0)
            console.log('[Afterglow] frame ' + this._frames + ': ' + due.length + ' callback(s), layer ' + (this._fbo ? 'bound' : 'none') +
                ', pose ' + (frame._poseSeen ? 'given' : 'not asked') + ', next ' + this._callbacks.length);
        if (this._callbacks.length) this._schedule();
    };

    // Draws the exit button into each eye's half of the eye framebuffer, over whatever the page
    // drew (no depth test: it is always visible), and puts the page's GL state back.
    XRSession.prototype._drawExit = function () {
        var gl = this._gl, d = this._distort;
        var e = d && d.exit;
        if (!e || !exitButton.shown) return;
        var saved = saveState(gl, d.vao);
        var blend = [gl.getParameter(gl.BLEND_SRC_RGB), gl.getParameter(gl.BLEND_DST_RGB), gl.getParameter(gl.BLEND_SRC_ALPHA),
                     gl.getParameter(gl.BLEND_DST_ALPHA), gl.getParameter(gl.BLEND_EQUATION_RGB), gl.getParameter(gl.BLEND_EQUATION_ALPHA)];
        var mask = gl.getParameter(gl.DEPTH_WRITEMASK);
        gl.bindFramebuffer(gl.FRAMEBUFFER, this._fbo);
        gl.disable(gl.DEPTH_TEST);
        gl.disable(gl.CULL_FACE);
        gl.disable(gl.SCISSOR_TEST);
        gl.depthMask(false);
        gl.enable(gl.BLEND);
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.useProgram(e.program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, e.textures[exitButton.hovered ? 1 : 0]);
        gl.uniform1i(e.uTex, 0);
        if (d.vao) d.vao.bind(e.array);
        else {
            gl.bindBuffer(gl.ARRAY_BUFFER, e.pos); gl.enableVertexAttribArray(e.aPos); gl.vertexAttribPointer(e.aPos, 2, gl.FLOAT, false, 0, 0);
            gl.bindBuffer(gl.ARRAY_BUFFER, e.uv); gl.enableVertexAttribArray(e.aUv); gl.vertexAttribPointer(e.aUv, 2, gl.FLOAT, false, 0, 0);
        }
        var model = fromQuatPos(exitButton.q, exitButton.c);
        for (var i = 0; i < 3; i++) { model[i] *= exitButton.w; model[4 + i] *= exitButton.h; }
        var near = 0.05, far = 100;
        var eyes = cfg.mono ? [-1] : [0, 1];
        var half = cfg.mono ? this._fbWidth : this._fbWidth / 2;
        for (var k = 0; k < eyes.length; k++) {
            var eye = eyes[k];
            var offset = eye < 0 ? [0, 0, 0] : rotateVec(pose.q, [(eye === 0 ? -0.5 : 0.5) * cfg.interLens, 0, 0]);
            var eyePos = [pose.p[0] + offset[0], pose.p[1] + offset[1], pose.p[2] + offset[2]];
            var view = invertRigid(fromQuatPos(pose.q, eyePos));
            var proj = eye < 0 ? monoProjection(near, far) : projection(eye, near, far);
            gl.viewport(eye === 1 ? half : 0, 0, half, this._fbHeight);
            gl.uniformMatrix4fv(e.uMvp, false, multiply(proj, multiply(view, model)));
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }
        if (d.vao) d.vao.bind(null);
        gl.blendFuncSeparate(blend[0], blend[1], blend[2], blend[3]);
        gl.blendEquationSeparate(blend[4], blend[5]);
        gl.depthMask(mask);
        restoreState(gl, d.vao, saved);
    };

    // Warps both halves of the eye framebuffer onto the screen through the lens meshes, and
    // leaves the page's GL state exactly as it found it.
    XRSession.prototype._composite = function () {
        var gl = this._gl, d = this._distort;
        if (!d) return;
        var saved = saveState(gl, d.vao);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, this._fbWidth, this._fbHeight);
        gl.disable(gl.DEPTH_TEST);
        gl.disable(gl.CULL_FACE);
        gl.disable(gl.BLEND);
        gl.disable(gl.SCISSOR_TEST);
        // Black outside the lens's reach, which is what the viewer's shell shows anyway; in AR
        // clear, for the app's passthrough underneath to show.
        gl.clearColor(0, 0, 0, this._ar ? 0 : 1);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.useProgram(d.program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, this._tex);
        gl.uniform1i(d.uTex, 0);

        if (cfg.mono) {
            bindMesh(gl, d, d.flat);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        } else {
            for (var eye = 0; eye < 2; eye++) {
                var m = d.eyes[eye];
                bindMesh(gl, d, m);
                gl.drawElements(gl.TRIANGLES, m.count, gl.UNSIGNED_SHORT, 0);
            }
        }
        if (d.vao) d.vao.bind(null);
        restoreState(gl, d.vao, saved);
    };

    XRSession.prototype.end = function () {
        if (this._ended) return Promise.resolve();
        this._ended = true;
        exitButton.shown = false;
        roomPlanes = [];
        var was = this._arWas;
        if (was) {
            was.hidden.forEach(function (h) { h.el.style.visibility = h.was; });
            document.documentElement.style.background = was.html;
            document.body.style.background = was.body;
            this._arWas = null;
        }
        this._callbacks = [];
        for (var side in handSources) if (handSources[side]) { handSources[side]._present = false; handSources[side]._pinching = false; }
        var gl = this._gl;
        var canvasWas = this._canvasWas;
        if (canvasWas && gl && gl.canvas) {
            if (canvasWas.style === null) gl.canvas.removeAttribute('style'); else gl.canvas.setAttribute('style', canvasWas.style);
            gl.canvas.width = canvasWas.width;
            gl.canvas.height = canvasWas.height;
            this._canvasWas = null;
        }
        var home = this._canvasHome;
        if (home && gl && gl.canvas && home.parent) {
            try {
                if (home.next && home.next.parentNode === home.parent) home.parent.insertBefore(gl.canvas, home.next);
                else home.parent.appendChild(gl.canvas);
            } catch (e) { /* the page took its canvas elsewhere */ }
            this._canvasHome = null;
        }
        if (gl) {
            gl.bindFramebuffer(gl.FRAMEBUFFER, null);
            if (this._fbo) gl.deleteFramebuffer(this._fbo);
            if (this._tex) gl.deleteTexture(this._tex);
            if (this._depth) gl.deleteRenderbuffer(this._depth);
        }
        this._emit('end');
        // Lets the app put its own view back, and says who asked, since a session that ends a
        // moment after it started is a page's decision the app can't otherwise see.
        var why = '';
        try { why = String((new Error('end')).stack || '').split('\n').slice(1, 7).join(' | '); } catch (e) { why = ''; }
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.afterglow)
            window.webkit.messageHandlers.afterglow.postMessage({ event: 'sessionend', why: why,
                fps: this._sessionStart && performance.now() - this._sessionStart > 3000 ? this._frames * 1000 / (performance.now() - this._sessionStart) : 0 });
        return Promise.resolve();
    };

    // The app ends the session: a long press on the screen, since the page's own controls
    // can't be reached from inside the viewer.
    window.__afterglowEndSession = function () {
        if (!active || active._ended) return false;
        console.log('[Afterglow] session ended by the app');
        active.end();
        return true;
    };

    // A pinch in front of the camera, or a tap, arrives here from the app.
    window.__afterglowSelect = function () {
        if (!active || active._ended) return;
        var source = active.inputSources[0];
        active._emit('selectstart', { inputSource: source, frame: new XRFrame(active) });
        active._emit('select', { inputSource: source, frame: new XRFrame(active) });
        active._emit('selectend', { inputSource: source, frame: new XRFrame(active) });
    };

    // ---------------------------------------------------------------- navigator.xr
    var active = null;

    // WebKit fires a window resize (and may fire orientationchange) as the app takes the screen
    // for a session, with nothing about the window changed: the same inner size, the same
    // visual viewport. A page that rebuilds its renderer on resize (a 360 player did) would
    // dispose the very thing it just put into the session. A browser entering immersive mode
    // fires neither, so during a session a resize that changes nothing is not delivered. These
    // listeners are registered before any page script and in the capture phase, so they run
    // first and can stop the rest.
    var lastInner = [window.innerWidth, window.innerHeight];
    function swallowIfUnchanged(e) {
        var w = window.innerWidth, h = window.innerHeight;
        var changed = w !== lastInner[0] || h !== lastInner[1];
        lastInner = [w, h];
        if (active && !active._ended && !changed) {
            e.stopImmediatePropagation();
            console.log('[Afterglow] ' + e.type + ' during the session with the window unchanged (' + w + 'x' + h + '): not delivered');
        }
    }
    window.addEventListener('resize', swallowIfUnchanged, true);
    window.addEventListener('orientationchange', swallowIfUnchanged, true);
    navigator.xr = {
        isSessionSupported: function (mode) {
            return Promise.resolve(mode === 'immersive-vr' || mode === 'inline' || (mode === 'immersive-ar' && !!cfg.ar));
        },
        requestSession: function (mode, options) {
            var ar = mode === 'immersive-ar' && !!cfg.ar;
            if (mode !== 'immersive-vr' && mode !== 'inline' && !ar)
                return Promise.reject(new DOMException('Afterglow supports immersive-vr, immersive-ar and inline only', 'NotSupportedError'));
            // What an AR page needs and this can give; one that requires more should fail honestly.
            var known = ['viewer', 'local', 'local-floor', 'hit-test', 'hand-tracking'];
            var required = (options && options.requiredFeatures) || [];
            if (ar) for (var i = 0; i < required.length; i++) if (known.indexOf(required[i]) < 0)
                return Promise.reject(new DOMException('Afterglow has no "' + required[i] + '" feature', 'NotSupportedError'));
            var enabled = required.concat(((options && options.optionalFeatures) || []).filter(function (f) { return known.indexOf(f) >= 0; }));
            var post = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.afterglow;
            function start() {
                active = new XRSession();
                active.inputSources = [new XRInputSource()];
                active.enabledFeatures = enabled;
                if (ar) { active._ar = true; active.environmentBlendMode = 'alpha-blend'; }
                if (post) post.postMessage({ event: 'sessionstart', mode: mode });
                return active;
            }
            // The native app first lays the page out at 1:1 (its text zoom made the page small and
            // broke sessions), then says ready; the resize lands before there is a session for it
            // to end. A second without even a hold from the app starts the session anyway.
            if (!cfg.prepareSession || !post) return Promise.resolve(start());
            return new Promise(function (resolve) {
                var done = false, timer = null;
                function go() { if (done) return; done = true; window.__afterglowSessionReady = null; window.__afterglowSessionHold = null; resolve(start()); }
                window.__afterglowSessionReady = function () { requestAnimationFrame(function () { requestAnimationFrame(go); }); };
                // The app holds the request while the wearer answers whether the page may have their hands.
                window.__afterglowSessionHold = function () { clearTimeout(timer); };
                timer = setTimeout(go, 1000);
                post.postMessage({ event: 'sessionrequest', mode: mode });
            });
        },
        addEventListener: function () {},
        removeEventListener: function () {},
        ondevicechange: null
    };

    // Pages call this before handing the context to a layer.
    if (window.WebGLRenderingContext && !WebGLRenderingContext.prototype.makeXRCompatible)
        WebGLRenderingContext.prototype.makeXRCompatible = function () { return Promise.resolve(); };
    if (window.WebGL2RenderingContext && !WebGL2RenderingContext.prototype.makeXRCompatible)
        WebGL2RenderingContext.prototype.makeXRCompatible = function () { return Promise.resolve(); };

    window.XRWebGLLayer = XRWebGLLayer;
    window.XRRigidTransform = XRRigidTransform;
    window.XRRay = XRRay;
    window.XRHitTestSource = XRHitTestSource;
    window.XRHitTestResult = XRHitTestResult;
    window.XRSession = XRSession;
    window.XRFrame = XRFrame;
    window.XRView = XRView;
    window.XRViewerPose = XRViewerPose;
    window.XRReferenceSpace = XRReferenceSpace;
    window.XRInputSource = XRInputSource;
    window.XRHand = XRHand;
    window.XRJointSpace = XRJointSpace;

    console.log('[Afterglow] WebXR ready' + (cfg.mono ? ' (phone view: one picture, no lens correction)' : '') + ': screen ' + cfg.screen[0].toFixed(4) + ' x ' +
                cfg.screen[1].toFixed(4) + ' m, lenses ' + (cfg.interLens * 1000).toFixed(1) + ' mm apart; native XRWebGLBinding ' +
                (typeof window.XRWebGLBinding !== 'undefined' ? 'present' : 'absent') + ', native XRSystem ' + (typeof window.XRSystem !== 'undefined' ? 'present' : 'absent'));
})();
