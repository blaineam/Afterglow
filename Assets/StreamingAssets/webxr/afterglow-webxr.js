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
// What it does not do: hit testing, anchors, planes, depth, hand input, bounded or unbounded
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
    function screenAspect() {
        var w = window.innerWidth || 1, h = window.innerHeight || 1;
        return w / h;
    }

    // ---------------------------------------------------------------- head pose
    var pose = { p: [0, 0, 0], q: [0, 0, 0, 1] };
    window.__afterglowPose = function (px, py, pz, qx, qy, qz, qw) {
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
        var q = pose.q;
        // A floor-relative space puts the origin under the user rather than at the head.
        var lift = space && space._kind === 'local-floor' ? (cfg.eyeHeight || 1.6) : 0;
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
    // Only the viewer's own spaces have a pose here: the gaze ray starts at the head, and there
    // is nothing else being tracked. Anything else returns null, which is what a page should see
    // for a space this cannot locate.
    XRFrame.prototype.getPose = function (space, base) {
        if (!space || (space._kind !== 'viewer' && space._kind !== 'local' && space._kind !== 'local-floor'))
            return null;
        var viewer = this.getViewerPose(base);
        return viewer ? { transform: viewer.transform, emulatedPosition: viewer.emulatedPosition } : null;
    };

    function XRInputSource() {
        this.handedness = 'none';
        this.targetRayMode = 'gaze';
        this.targetRaySpace = new XRReferenceSpace('viewer');
        this.gripSpace = null;
        this.profiles = [];
        this.gamepad = null;
    }

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
            eyes: []
        };
        // Phone view draws through this instead: the framebuffer straight onto the screen, with
        // no warp, because there is no lens in front of it.
        var flatPos = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, flatPos);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
        var flatUv = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, flatUv);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0,0, 1,0, 0,1, 1,1]), gl.STATIC_DRAW);
        d.flat = { pos: flatPos, uv: flatUv };

        for (var eye = 0; eye < 2; eye++) {
            var m = distortionMesh(eye);
            var pos = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, pos);
            gl.bufferData(gl.ARRAY_BUFFER, m.pos, gl.STATIC_DRAW);
            var uv = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, uv);
            gl.bufferData(gl.ARRAY_BUFFER, m.uv, gl.STATIC_DRAW);
            var idx = gl.createBuffer();
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idx);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, m.idx, gl.STATIC_DRAW);
            d.eyes.push({ pos: pos, uv: uv, idx: idx, count: m.idx.length });
        }
        return d;
    }

    // ---------------------------------------------------------------- session lifecycle
    XRSession.prototype._attachLayer = function (layer, gl) {
        this._gl = gl;
        var dpr = window.devicePixelRatio || 1;
        var canvas = gl.canvas;
        var w = Math.max(2, Math.floor(window.innerWidth * dpr));
        var h = Math.max(2, Math.floor(window.innerHeight * dpr));
        canvas.width = w;
        canvas.height = h;
        canvas.style.position = 'fixed';
        canvas.style.left = '0';
        canvas.style.top = '0';
        canvas.style.width = '100%';
        canvas.style.height = '100%';
        canvas.style.zIndex = '2147483647';
        this._fbWidth = w;
        this._fbHeight = h;

        var target = createTarget(gl, w, h);
        if (target) { this._fbo = target.fbo; this._tex = target.tex; this._depth = target.depth; }
        this._distort = createDistortion(gl);
        this.renderState.baseLayer = layer;
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
            catch (e) { console.error('[Afterglow] frame callback: ' + (e && e.message)); }
        }
        if (gl && this._fbo) this._composite();
        if (this._callbacks.length) this._schedule();
    };

    // Warps both halves of the eye framebuffer onto the screen through the lens meshes.
    XRSession.prototype._composite = function () {
        var gl = this._gl, d = this._distort;
        if (!d) return;
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, this._fbWidth, this._fbHeight);
        gl.disable(gl.DEPTH_TEST);
        gl.disable(gl.CULL_FACE);
        gl.disable(gl.BLEND);
        gl.disable(gl.SCISSOR_TEST);
        // Black outside the lens's reach, which is what the viewer's shell shows anyway.
        gl.clearColor(0, 0, 0, 1);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.useProgram(d.program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, this._tex);
        gl.uniform1i(d.uTex, 0);

        if (cfg.mono) {
            gl.bindBuffer(gl.ARRAY_BUFFER, d.flat.pos);
            gl.enableVertexAttribArray(d.aPos);
            gl.vertexAttribPointer(d.aPos, 2, gl.FLOAT, false, 0, 0);
            gl.bindBuffer(gl.ARRAY_BUFFER, d.flat.uv);
            gl.enableVertexAttribArray(d.aUv);
            gl.vertexAttribPointer(d.aUv, 2, gl.FLOAT, false, 0, 0);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            return;
        }

        for (var eye = 0; eye < 2; eye++) {
            var m = d.eyes[eye];
            gl.bindBuffer(gl.ARRAY_BUFFER, m.pos);
            gl.enableVertexAttribArray(d.aPos);
            gl.vertexAttribPointer(d.aPos, 2, gl.FLOAT, false, 0, 0);
            gl.bindBuffer(gl.ARRAY_BUFFER, m.uv);
            gl.enableVertexAttribArray(d.aUv);
            gl.vertexAttribPointer(d.aUv, 2, gl.FLOAT, false, 0, 0);
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, m.idx);
            gl.drawElements(gl.TRIANGLES, m.count, gl.UNSIGNED_SHORT, 0);
        }
    };

    XRSession.prototype.end = function () {
        if (this._ended) return Promise.resolve();
        this._ended = true;
        this._callbacks = [];
        var gl = this._gl;
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
            window.webkit.messageHandlers.afterglow.postMessage({ event: 'sessionend', why: why });
        return Promise.resolve();
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
    navigator.xr = {
        isSessionSupported: function (mode) {
            return Promise.resolve(mode === 'immersive-vr' || mode === 'inline');
        },
        requestSession: function (mode) {
            if (mode !== 'immersive-vr' && mode !== 'inline')
                return Promise.reject(new Error('Afterglow supports immersive-vr and inline only'));
            active = new XRSession();
            active.inputSources = [new XRInputSource()];
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.afterglow)
                window.webkit.messageHandlers.afterglow.postMessage({ event: 'sessionstart' });
            return Promise.resolve(active);
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
    window.XRSession = XRSession;
    window.XRFrame = XRFrame;
    window.XRView = XRView;
    window.XRViewerPose = XRViewerPose;
    window.XRReferenceSpace = XRReferenceSpace;

    console.log('[Afterglow] WebXR ready' + (cfg.mono ? ' (phone view: one picture, no lens correction)' : '') + ': screen ' + cfg.screen[0].toFixed(4) + ' x ' +
                cfg.screen[1].toFixed(4) + ' m, lenses ' + (cfg.interLens * 1000).toFixed(1) + ' mm apart');
})();
