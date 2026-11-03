// A WebXR implementation for pages shown inside CardboardXR's browser.
//
// Safari has no WebXR on iOS -- not in 26, not in 27; immersive sessions are Vision Pro only -- so
// a page opened here finds no navigator.xr and falls back to a flat view. This supplies one.
//
// It is not a polyfill of the usual kind, which reads the phone's own orientation sensors through
// DeviceOrientation. The app around this page already has a fused head pose (gyroscope corrected
// by ARKit), which is better than anything the page could get for itself, and it pushes that pose
// in through __cardboardxrPose. What this file does is turn that pose, and the viewer's measured
// optics, into the matrices a WebXR page expects, split the canvas into two eyes, and -- after the
// page has drawn -- warp both halves through the lenses' barrel distortion.
//
// The distortion is ported from this project's own LensDistortion.cs, which is itself ported from
// the Cardboard SDK (sdk/lens_distortion.cc, sdk/polynomial_radial_distortion.cc, Apache 2.0), so
// a page here is corrected with exactly the numbers the native app corrects itself with.
//
// What it does not do: hit testing, anchors, planes, depth, hand input, bounded or unbounded
// reference spaces, or anything AR. Pages built on three.js or A-Frame that ask for an
// immersive-vr session, a local or viewer reference space and a WebGL layer will run. Pages that
// reach past that will not, and should fail honestly rather than silently.

(function () {
    'use strict';

    if (navigator.xr) return;                       // a real implementation; leave it alone
    var cfg = window.__cardboardxrConfig;
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

    // ---------------------------------------------------------------- head pose
    var pose = { p: [0, 0, 0], q: [0, 0, 0, 1] };
    window.__cardboardxrPose = function (px, py, pz, qx, qy, qz, qw) {
        pose.p[0] = px; pose.p[1] = py; pose.p[2] = pz;
        pose.q[0] = qx; pose.q[1] = qy; pose.q[2] = qz; pose.q[3] = qw;
    };

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

    function XRView(eye, viewMatrix, projectionMatrix, transform) {
        this.eye = eye === 0 ? 'left' : 'right';
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
