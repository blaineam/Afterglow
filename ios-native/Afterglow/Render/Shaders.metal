// Afterglow's shaders. The scene passes (sky, floor, passthrough, overlay) draw both eyes in one
// draw with vertex amplification: the amplification id picks the eye's uniforms, and the pass's
// view mappings add the eye's slice to the render target array index the vertex writes, which is
// therefore always 0 here (writing the eye index too sent the right eye to slice 2, out of range,
// and both eyes landed on the left slice: 2026-11-06). Without amplification (the Simulator) the
// pass is bound to one slice and 0 is right as well. The distortion pass then warps each slice
// onto its half of the screen with the viewer's lens geometry.
#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct SceneOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
    float2 ndc;
    float3 worldPos;
    ushort eye [[flat]];
};

// ---- Full-screen direction passes (sky, passthrough) ----------------------------------------

// One triangle covering the view, per eye.
vertex SceneOut fullscreenVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]]) {
    const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SceneOut out;
    out.position = float4(corners[vid], 0.5, 1);
    out.layer = 0;
    out.ndc = corners[vid];
    out.worldPos = float3(0);
    out.eye = amp;
    return out;
}

// The world direction a pixel looks along, from its NDC through the eye's projection and rotation.
static float3 worldDirection(float2 ndc, constant EyeUniforms &eye) {
    float4 view = eye.inverseProjection * float4(ndc, 1, 1);
    float3 dir = normalize(view.xyz / view.w);
    return normalize((eye.worldFromView * float4(dir, 0)).xyz);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// A synthwave sunset: a sky grading from deep violet to hot pink at the horizon, a striped sun
// sinking behind dark mountains straight ahead, stars overhead. The same colours as the Unity
// app's generated Synth Sky texture.
fragment float4 skyFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]]) {
    float3 dir = worldDirection(in.ndc, frame.eyes[in.eye]);
    const float3 zenith = float3(0.07, 0.01, 0.20);
    const float3 upper = float3(0.30, 0.05, 0.45);
    const float3 horizon = float3(1.00, 0.25, 0.55);
    const float3 glow = float3(1.00, 0.55, 0.30);
    const float3 ground = float3(0.05, 0.01, 0.12);
    const float3 sunTop = float3(1.00, 0.85, 0.35);
    const float3 sunBottom = float3(1.00, 0.20, 0.60);
    const float3 mountain = float3(0.12, 0.02, 0.22);

    float up = dir.y;                        // -1..1, 0 at the horizon
    float azimuth = atan2(dir.x, -dir.z);    // 0 straight ahead (-z), where the sun is
    float3 color;
    if (up < 0.0) {
        color = ground;
    } else if (up < 0.12) {
        color = mix(glow, horizon, up / 0.12);
    } else if (up < 0.5) {
        color = mix(horizon, upper, (up - 0.12) / 0.38);
    } else {
        color = mix(upper, zenith, (up - 0.5) / 0.5);
    }

    // The sun: a disc ahead, sitting on the horizon, cut by dark bands in its lower half.
    float2 sunCenter = float2(0.0, 0.10);
    float radius = 0.16;
    float2 d = float2(azimuth, up) - sunCenter;
    float r = length(d) / radius;
    if (r < 1.0 && up > 0.0) {
        float inSun = (d.y + radius) / (2.0 * radius);
        float3 sun = mix(sunBottom, sunTop, inSun);
        float band = (inSun < 0.55 && fract(inSun * 14.0) < 0.45 * (1.0 - inSun / 0.55)) ? 1.0 : 0.0;
        float3 disc = mix(sun, color, band);
        color = mix(disc, color, smoothstep(0.9, 1.0, r));
    }

    // Stars, more of them higher up, none near the bright horizon: one small round dot in the
    // cells the hash picks, placed within its cell by a second hash so they don't line up.
    if (up > 0.25) {
        float2 sky = float2(azimuth * 60.0, up * 120.0);
        float2 cell = floor(sky);
        float h = hash21(cell);
        if (h > 0.985 - 0.012 * up) {
            float2 at = float2(hash21(cell + 7.3), hash21(cell + 2.1)) * 0.6 + 0.2;
            float2 d = (fract(sky) - at) * float2(1.0, 2.0);
            float twinkle = 0.75 + 0.25 * sin(frame.time * 2.0 + h * 40.0);
            float dot_ = 1.0 - smoothstep(0.05, 0.12, length(d));
            color = mix(color, float3(1.0), 0.7 * twinkle * dot_);
        }
    }

    // Mountains: a dark silhouette along the horizon, a ridge line of a few waves.
    float ridge = 0.035 + 0.025 * sin(azimuth * 3.1 + 0.4) + 0.018 * sin(azimuth * 7.3 + 2.0) + 0.012 * sin(azimuth * 13.7);
    ridge *= (1.0 - 0.6 * smoothstep(0.0, 0.5, abs(azimuth)) * 0.0); // uniform ring of hills
    if (up >= 0.0 && up < ridge) {
        color = up > ridge - 0.004 ? mix(mountain, upper, 0.35) : mountain;
    }
    return float4(color, 1.0);
}

// ---- The neon floor ------------------------------------------------------------------------

// A large quad at the floor's height, drawn after the sky so it covers the ground half.
vertex SceneOut floorVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                            constant FrameUniforms &frame [[buffer(0)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1),
                                float2(-1, -1), float2(1, 1), float2(-1, 1) };
    constant EyeUniforms &eye = frame.eyes[amp];
    const float extent = 300.0;
    // Centred under the eye so the far edge never comes into view as the user walks.
    float2 c = corners[vid] * extent + eye.eyePosition.xz;
    float3 world = float3(c.x, frame.floorHeight, c.y);
    SceneOut out;
    out.position = eye.viewProjection * float4(world, 1);
    out.layer = 0;
    out.ndc = float2(0);
    out.worldPos = world;
    out.eye = amp;
    return out;
}

// One-metre cells of neon on near-black, fading to the horizon's glow in the distance.
fragment float4 floorFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]]) {
    const float3 background = float3(0.04, 0.01, 0.10);
    const float3 line = float3(1.00, 0.20, 0.85);
    const float3 glowColor = float3(0.55, 0.10, 0.60);
    const float3 horizonGlow = float3(1.00, 0.55, 0.30);

    float2 p = in.worldPos.xz + float2(0.0, frame.floorScroll);
    float3 lineColor = frame.gridColor.w > 0.5 ? frame.gridColor.rgb : line;
    float2 grid = abs(fract(p - 0.5) - 0.5);          // distance to the nearest line, per axis
    float2 width = fwidth(p);
    float2 aa = max(width, 0.002);
    float2 lineMask = 1.0 - smoothstep(0.0, aa * 1.5, grid - 0.012);
    float lines = max(lineMask.x, lineMask.y);
    float2 glowMask = 1.0 - smoothstep(0.0, 0.18, grid);
    float glowAmount = max(glowMask.x, glowMask.y) * 0.35;
    float pulse = 0.9 + 0.1 * sin(frame.time * 1.5 - length(p - frame.eyes[in.eye].eyePosition.xz) * 0.4);

    float3 color = background;
    color = mix(color, glowColor, glowAmount);
    color = mix(color, lineColor * pulse, lines);

    // Fade into the horizon's glow with distance, so the far edge of the quad dissolves and the
    // lines stop shimmering where they bunch up.
    float3 toPoint = in.worldPos - frame.eyes[in.eye].eyePosition.xyz;
    float distance = length(toPoint);
    float fog = 1.0 - exp(-distance * 0.03);
    color = mix(color, horizonGlow * 0.9, fog * fog);
    return float4(color, 1.0);
}

// ---- Passthrough ---------------------------------------------------------------------------

// The camera image, reprojected: each pixel's direction is turned into the axes of the camera that
// took the image, and that direction says where in the image to sample. Depth drops out and so
// does where the head is, only which way it faces moves the picture; the image is shown at its own
// field of view, so the room is life size. Pixels the camera did not see are black, with a soft rim.
fragment float4 passthroughFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]],
                                    texture2d<float> lumaTexture [[texture(0)]],
                                    texture2d<float> chromaTexture [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 dir = worldDirection(in.ndc, frame.eyes[in.eye]);
    float3 inCamera = (frame.captureFromWorld * float4(dir, 0)).xyz;
    if (inCamera.z >= -1e-4 || frame.captureIntrinsics.x <= 0.0) {
        return float4(0, 0, 0, 1);
    }
    float2 tangent = float2(inCamera.x, -inCamera.y) / -inCamera.z;
    float2 uv = tangent * frame.captureIntrinsics.xy + frame.captureIntrinsics.zw;
    float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    if (edge < 0.0) {
        return float4(0, 0, 0, 1);
    }
    float y = lumaTexture.sample(s, uv).r;
    float2 cbcr = chromaTexture.sample(s, uv).rg - 0.5;
    if (frame.captureVideoRange > 0.5) {
        // Video range: Y 16-235 and C 16-240 of 255 (the same fractions for 10-bit samples).
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cbcr *= 255.0 / 224.0;
    }
    // BT.709.
    float3 rgb = float3(y + 1.5748 * cbcr.y,
                        y - 0.1873 * cbcr.x - 0.4681 * cbcr.y,
                        y + 1.8556 * cbcr.x);
    float rim = smoothstep(0.0, 0.03, edge);
    return float4(rgb * rim, 1.0);
}

// ---- Hands and demo objects ---------------------------------------------------------------

struct OverlayOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
    float4 color;
};

vertex OverlayOut overlayVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                                const device OverlayVertex *vertices [[buffer(1)]],
                                constant FrameUniforms &frame [[buffer(0)]]) {
    OverlayVertex v = vertices[vid];
    OverlayOut out;
    out.position = frame.eyes[amp].viewProjection * float4(v.position, 1);
    out.layer = 0;
    out.color = v.color;
    return out;
}

fragment float4 overlayFragment(OverlayOut in [[stage_in]]) {
    return in.color;
}

// ---- Detected surfaces (the room) ----------------------------------------------------------

struct SurfaceOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
    float3 worldPos;
    float2 local;
    float2 extent;
};

vertex SurfaceOut surfaceVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                                const device SurfaceVertex *vertices [[buffer(1)]],
                                constant FrameUniforms &frame [[buffer(0)]]) {
    SurfaceVertex v = vertices[vid];
    SurfaceOut out;
    out.position = frame.eyes[amp].viewProjection * float4(v.position, 1);
    out.layer = 0;
    out.worldPos = v.position;
    out.local = v.local;
    out.extent = v.extent;
    return out;
}

// Real surfaces marked the way the Unity app marks them: small X marks on a grid, the plane's
// edges faded, a faint fill, and a soft highlight spot where the gaze meets a surface.
fragment float4 surfaceFragment(SurfaceOut in [[stage_in]], constant SurfaceUniforms &u [[buffer(2)]]) {
    float2 cell = fract(in.local / u.spacing + 0.5) - 0.5;      // -0.5..0.5 within a cell
    float2 p = abs(cell * u.spacing);                           // metres from the cell's centre
    float arm = 0.035;
    // An X: the distance to the diagonal, anti-aliased by the pixel's footprint so a mark is
    // never thinner than a pixel however far the surface is.
    float d = abs(p.x - p.y) * 0.7071;
    float footprint = max(fwidth(in.local.x), fwidth(in.local.y));
    float width = max(0.006, footprint * 0.8);
    float mark = (1.0 - smoothstep(width, width + footprint, d)) * (max(p.x, p.y) < arm ? 1.0 : 0.0);
    // The edge fade: within 0.4 m of the plane's edge the marks dim.
    float2 toEdge = in.extent - abs(in.local);
    float edge = clamp(min(toEdge.x, toEdge.y) / 0.4, 0.0, 1.0);
    float fill = 0.06;
    float3 color = u.color.rgb;
    float alpha = (fill + mark * 0.9) * edge * u.appear;
    if (u.gazePoint.w > 0.5) {
        float spot = 1.0 - smoothstep(0.0, 0.25, length(in.worldPos - u.gazePoint.xyz));
        color = mix(color, u.highlightColor.rgb, spot);
        alpha += spot * (0.16 + mark * 0.4) * edge;
    }
    return float4(color * alpha, alpha);
}

// ---- Occlusion by the real room ------------------------------------------------------------

// Writes the LiDAR depth into the eye's depth buffer: each pixel's direction is taken into the
// camera's axes, the depth map sampled there, and the point placed along the ray, so anything
// virtual drawn after with a depth test hides behind real walls, tables and hands.
struct DepthOut { float depth [[depth(any)]]; };

fragment DepthOut occlusionFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]],
                                    texture2d<float> depthMap [[texture(0)]],
                                    texture2d<uint> confidence [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 dir = worldDirection(in.ndc, frame.eyes[in.eye]);
    float3 inCamera = (frame.captureFromWorld * float4(dir, 0)).xyz;
    DepthOut out;
    out.depth = 1.0;
    if (inCamera.z >= -1e-4) return out;
    float2 tangent = float2(inCamera.x, -inCamera.y) / -inCamera.z;
    float2 uv = tangent * frame.captureIntrinsics.xy + frame.captureIntrinsics.zw;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return out;
    uint c = confidence.read(uint2(uv * float2(confidence.get_width(), confidence.get_height()))).r;
    if (c < 1) return out;
    float z = depthMap.sample(s, uv).r;              // metres along the camera's axis
    if (z <= 0.05) return out;
    // The point in the eye's clip space: along the eye's ray by the same distance (the eye and the
    // camera sit a few centimetres apart, which at room distances is below the depth map's grain).
    float3 eye = frame.eyes[in.eye].eyePosition.xyz;
    float3 world = eye + dir * (z / -inCamera.z);
    float4 clip = frame.eyes[in.eye].viewProjection * float4(world, 1);
    out.depth = clamp(clip.z / clip.w, 0.0, 1.0);
    return out;
}

// ---- Media projections (360, 180, fisheye, cylinder) --------------------------------------

// Drawn as a full-screen pass like the sky: each pixel's world direction is turned into a
// texture coordinate by the projection, with the eye's half of the picture for stereo layouts.
fragment float4 mediaFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]],
                              constant MediaUniforms &media [[buffer(1)]],
                              texture2d<float> picture [[texture(0)]],
                              texture2d_array<float> eyes [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 dir = worldDirection(in.ndc, frame.eyes[in.eye]);
    // Turn the picture to face `yaw`.
    float cy = cos(-media.yaw), sy = sin(-media.yaw);
    dir = float3(dir.x * cy - dir.z * sy, dir.y, dir.x * sy + dir.z * cy);
    float2 uv;
    bool inside = true;
    if (media.projection == MediaProjectionEquirect360) {
        float lon = atan2(dir.x, -dir.z);               // 0 ahead, + to the right
        float lat = asin(clamp(dir.y, -1.0, 1.0));
        uv = float2(0.5 + lon / (2.0 * M_PI_F), 0.5 - lat / M_PI_F);
    } else if (media.projection == MediaProjectionEquirect180) {
        float lon = atan2(dir.x, -dir.z);
        float lat = asin(clamp(dir.y, -1.0, 1.0));
        float halfSpan = media.span * 0.5;
        inside = abs(lon) <= halfSpan;
        uv = float2(0.5 + lon / media.span, 0.5 - lat / M_PI_F);
    } else if (media.projection == MediaProjectionFisheye180) {
        // Equidistant: the angle from the axis maps linearly to the radius.
        float angle = acos(clamp(-dir.z, -1.0, 1.0));
        float halfSpan = media.span * 0.5;
        inside = angle <= halfSpan;
        float r = angle / halfSpan * 0.5;
        float2 flat = normalize(float2(dir.x, dir.y) + 1e-6);
        uv = float2(0.5 + flat.x * r, 0.5 - flat.y * r);
    } else {
        // Cylinder: longitude across the band, height by tangent.
        float lon = atan2(dir.x, -dir.z);
        float halfSpan = media.span * 0.5;
        float horizontal = length(float2(dir.x, dir.z));
        float t = dir.y / max(horizontal, 1e-4);
        inside = abs(lon) <= halfSpan && abs(t) <= media.height;
        uv = float2(0.5 + lon / media.span, 0.5 - t / (2.0 * media.height));
    }
    if (!inside) {
        return float4(0.02, 0.01, 0.05, 1.0);
    }
    uint eye = media.swapEyes != 0 ? 1 - in.eye : in.eye;
    float4 c;
    if (media.layout == MediaLayoutArray) {
        c = eyes.sample(s, uv, eye);
    } else {
        if (media.layout == MediaLayoutSideBySide) uv.x = uv.x * 0.5 + (eye == 0 ? 0.0 : 0.5);
        else if (media.layout == MediaLayoutTopBottom) uv.y = uv.y * 0.5 + (eye == 0 ? 0.0 : 0.5);
        c = picture.sample(s, uv);
    }
    return float4(c.rgb * media.brightness, 1.0);
}

// ---- Textured quads (the browser window) --------------------------------------------------

struct QuadOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
    float2 uv;
    ushort eye [[flat]];
};

vertex QuadOut quadVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                          const device QuadVertex *vertices [[buffer(1)]],
                          constant FrameUniforms &frame [[buffer(0)]]) {
    QuadVertex v = vertices[vid];
    QuadOut out;
    out.position = frame.eyes[amp].viewProjection * float4(v.position, 1);
    out.layer = 0;
    out.uv = v.uv;
    out.eye = amp;
    return out;
}

// The page texture, with a soft dark border so the window reads as a pane; `tint` is alpha for
// fading and a dimming factor.
fragment float4 quadFragment(QuadOut in [[stage_in]], texture2d<float> page [[texture(0)]],
                             constant float4 &tint [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = page.sample(s, in.uv);
    return float4(c.rgb * tint.rgb, tint.a);
}

// A flat picture or video in a frame ahead, with the eye's half for stereo layouts and no lens
// stretching: the quad pipeline's vertices, this fragment.
fragment float4 mediaQuadFragment(QuadOut in [[stage_in]], constant MediaUniforms &media [[buffer(1)]],
                                  texture2d<float> picture [[texture(0)]],
                                  texture2d_array<float> eyes [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    uint eye = media.swapEyes != 0 ? 1 - in.eye : in.eye;
    float2 uv = in.uv;
    float4 c;
    if (media.layout == MediaLayoutArray) {
        c = eyes.sample(s, uv, eye);
    } else {
        if (media.layout == MediaLayoutSideBySide) uv.x = uv.x * 0.5 + (eye == 0 ? 0.0 : 0.5);
        else if (media.layout == MediaLayoutTopBottom) uv.y = uv.y * 0.5 + (eye == 0 ? 0.0 : 0.5);
        c = picture.sample(s, uv);
    }
    return float4(c.rgb * media.brightness, 1.0);
}

// ---- Lens distortion -----------------------------------------------------------------------

struct DistortionOut {
    float4 position [[position]];
    float2 uv;
    uint eye [[flat]];
};

vertex DistortionOut distortionVertex(uint vid [[vertex_id]],
                                      const device DistortionVertex *vertices [[buffer(0)]]) {
    DistortionVertex v = vertices[vid];
    DistortionOut out;
    out.position = float4(v.position, 0, 1);
    out.uv = v.uv;
    out.eye = v.eye;
    return out;
}

fragment float4 distortionFragment(DistortionOut in [[stage_in]],
                                   texture2d_array<float> eyes [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    // The mesh's UVs have their origin at the bottom left (the SDK's convention); Metal textures
    // put row 0 at the top.
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    return float4(eyes.sample(s, uv, in.eye).rgb, 1.0);
}

// The screen between the two eyes' meshes, and outside them, is cleared black by the pass itself.

// ---- A flat copy of one eye (casting to a TV) ---------------------------------------------

struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blitVertex(uint vid [[vertex_id]]) {
    const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    BlitOut out;
    out.position = float4(corners[vid], 0, 1);
    out.uv = float2((corners[vid].x + 1) * 0.5, 1.0 - (corners[vid].y + 1) * 0.5);
    return out;
}

fragment float4 blitFragment(BlitOut in [[stage_in]], texture2d_array<float> eyes [[texture(0)]], constant uint &slice [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(eyes.sample(s, in.uv, slice).rgb, 1.0);
}
