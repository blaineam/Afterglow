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

static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise2(p); p *= 2.1; a *= 0.5; }
    return v;
}

// A sun or moon disc with a soft halo, in a direction.
static float3 disc(float3 dir, float3 sunDir, float radius, float3 color, float3 sky) {
    float d = acos(clamp(dot(dir, sunDir), -1.0, 1.0));
    float body = 1.0 - smoothstep(radius * 0.9, radius, d);
    float halo = exp(-d * d / (radius * radius * 12.0)) * 0.35;
    return mix(sky, color, body) + color * halo;
}

// The other places on the roadmap, each from a sky and a ground: a forest with a tree line and
// fireflies at night, a desert with dunes and heat, a beach with a sea, ruins with columns, a
// cyberpunk city of lit towers, the Moon and Mars with their skies. `night` goes 0 to 1; the
// stars and the lights come out as it does.
static float3 placeSky(float3 dir, float azimuth, float up, int kind, float night, float time) {
    float3 sunDir = normalize(float3(0.3, mix(0.35, -0.2, night), -1.0));
    float3 moonDir = normalize(float3(-0.5, 0.45, -0.7));
    float3 color;
    if (kind == EnvironmentMoon) {
        // No atmosphere: black, the stars sharp, the Earth hanging.
        color = float3(0.0);
        float2 cell = floor(float2(azimuth * 90.0, up * 180.0));
        if (hash21(cell) > 0.992) color = float3(1.0) * (0.6 + 0.4 * hash21(cell + 3.1));
        float3 earthDir = normalize(float3(-0.4, 0.5, -0.8));
        float d = acos(clamp(dot(dir, earthDir), -1.0, 1.0));
        if (d < 0.12) {
            float3 earth = mix(float3(0.2, 0.5, 1.0), float3(0.3, 0.7, 0.3), smoothstep(0.3, 0.7, fbm(float2(azimuth * 30.0, up * 30.0))));
            float lit = 0.3 + 0.7 * smoothstep(-0.02, 0.06, dot(normalize(dir - earthDir * cos(d)), float3(1, 0, 0)));
            color = earth * lit * (1.0 - smoothstep(0.11, 0.12, d)) + color * smoothstep(0.11, 0.12, d);
        }
        color = disc(dir, sunDir, 0.03, float3(1.0), color);
        return color;
    }
    if (kind == EnvironmentMars) {
        float3 day = mix(float3(0.85, 0.55, 0.35), float3(0.55, 0.35, 0.28), clamp(up * 2.0, 0.0, 1.0));
        float3 dark = float3(0.05, 0.02, 0.02);
        color = mix(day, dark, night);
        if (night > 0.3) {
            float2 cell = floor(float2(azimuth * 80.0, up * 160.0));
            if (hash21(cell) > 0.99) color += float3(1.0) * (night - 0.3) * 0.8;
        }
        color = disc(dir, sunDir, 0.025, float3(1.0, 0.95, 0.9), color);
        return color;
    }
    float3 zenithDay, horizonDay;
    if (kind == EnvironmentDesert) { zenithDay = float3(0.25, 0.5, 0.95); horizonDay = float3(0.95, 0.8, 0.6); }
    else if (kind == EnvironmentBeach) { zenithDay = float3(0.2, 0.55, 1.0); horizonDay = float3(0.8, 0.9, 1.0); }
    else if (kind == EnvironmentCity) { zenithDay = float3(0.35, 0.45, 0.6); horizonDay = float3(0.8, 0.6, 0.6); }
    else if (kind == EnvironmentRuins) { zenithDay = float3(0.3, 0.55, 0.9); horizonDay = float3(0.9, 0.85, 0.7); }
    else { zenithDay = float3(0.3, 0.6, 1.0); horizonDay = float3(0.75, 0.85, 0.95); }
    float3 zenithNight = float3(0.01, 0.02, 0.06), horizonNight = float3(0.05, 0.06, 0.14);
    if (kind == EnvironmentCity) horizonNight = float3(0.25, 0.08, 0.3);
    float t = clamp(up, 0.0, 1.0);
    color = mix(mix(horizonDay, zenithDay, sqrt(t)), mix(horizonNight, zenithNight, sqrt(t)), night);
    // Clouds by day, stars by night.
    float cloud = fbm(float2(azimuth * 3.0 + time * 0.01, up * 6.0)) ;
    if (up > 0.02 && kind != EnvironmentCity) color = mix(color, float3(1.0) * (1.0 - night * 0.9), smoothstep(0.55, 0.75, cloud) * 0.7 * (1.0 - night * 0.8));
    if (night > 0.2 && up > 0.05) {
        float2 cell = floor(float2(azimuth * 70.0, up * 140.0));
        if (hash21(cell) > 0.985) color += float3(1.0) * (night - 0.2) * (0.6 + 0.4 * sin(time * 3.0 + hash21(cell + 1.7) * 20.0));
    }
    float3 sunColor = mix(float3(1.0, 0.95, 0.85), float3(1.0, 0.5, 0.2), clamp(night * 2.0, 0.0, 1.0));
    color = disc(dir, sunDir, 0.04, sunColor, color) * (1.0 - night * 0.3);
    if (night > 0.5) color = disc(dir, moonDir, 0.03, float3(0.9, 0.95, 1.0), color);
    // Silhouettes on the horizon: a tree line, dunes, a sea's flat line, columns, towers.
    float ridge = 0.0;
    if (kind == EnvironmentForest) ridge = 0.06 + 0.04 * abs(sin(azimuth * 11.0)) + 0.03 * abs(sin(azimuth * 23.0 + 1.0));
    else if (kind == EnvironmentDesert) ridge = 0.04 + 0.03 * sin(azimuth * 2.3) + 0.01 * sin(azimuth * 7.0);
    else if (kind == EnvironmentRuins) ridge = (fract(azimuth * 2.5 + 0.5) < 0.12 && abs(azimuth) < 1.6) ? 0.16 : 0.03;
    else if (kind == EnvironmentCity) {
        float lane = floor(azimuth * 6.0);
        ridge = 0.08 + 0.18 * hash21(float2(lane, 1.0));
        float lit = step(0.5, hash21(floor(float2(azimuth * 40.0, up * 60.0))));
        if (up < ridge && up > 0.0) return mix(float3(0.05, 0.04, 0.08), float3(1.0, 0.8, 0.3) * lit * (0.3 + night), night * 0.8 * lit);
    }
    if (up >= 0.0 && up < ridge) {
        float3 dark = kind == EnvironmentDesert ? float3(0.55, 0.42, 0.3) : (kind == EnvironmentRuins ? float3(0.7, 0.65, 0.55) : float3(0.03, 0.08, 0.04));
        color = mix(dark, color, 0.15) * (1.0 - night * 0.7);
    }
    return color;
}

// Fireflies and city lights at night, rising slowly.
static float3 placeLights(float3 dir, float azimuth, float up, int kind, float night, float time) {
    if (night < 0.4 || up < -0.3 || up > 0.25) return float3(0.0);
    if (kind != EnvironmentForest && kind != EnvironmentBeach) return float3(0.0);
    float2 p = float2(azimuth * 20.0, up * 40.0 - time * 0.3);
    float2 cell = floor(p);
    float h = hash21(cell);
    float2 c = fract(p) - 0.5;
    float glow = exp(-dot(c, c) * 60.0) * step(0.93, h) * (0.5 + 0.5 * sin(time * 4.0 + h * 50.0));
    return float3(0.8, 1.0, 0.4) * glow * (night - 0.4);
}

// A synthwave sunset: a sky grading from deep violet to hot pink at the horizon, a striped sun
// sinking behind dark mountains straight ahead, stars overhead. The same colours as the Unity
// app's generated Synth Sky texture. The other places branch off at the top.
fragment float4 skyFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]]) {
    float3 dir = worldDirection(in.ndc, frame.eyes[in.eye]);
    if (frame.environment != EnvironmentSynthwave) {
        float up0 = dir.y;
        float az0 = atan2(dir.x, -dir.z);
        float3 c = placeSky(dir, az0, up0, frame.environment, frame.night, frame.time);
        c += placeLights(dir, az0, up0, frame.environment, frame.night, frame.time);
        return float4(c, 1.0);
    }
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

// The ground of the other places: forest floor, sand with dunes, a sea with ripples, flagstones,
// a wet street, regolith, red rock; lit by the time of day, fogged into the horizon.
static float4 placeFloor(float3 world, float3 eye, int kind, float night, float time) {
    float2 p = world.xz;
    float3 color;
    float3 toPoint = world - eye;
    float distance = length(toPoint);
    if (kind == EnvironmentForest) {
        float n = fbm(p * 0.8);
        color = mix(float3(0.1, 0.25, 0.08), float3(0.25, 0.4, 0.12), n);
        // Moss and leaf litter.
        color = mix(color, float3(0.35, 0.25, 0.12), smoothstep(0.6, 0.8, fbm(p * 2.3 + 7.0)) * 0.5);
    } else if (kind == EnvironmentDesert) {
        float dune = sin(p.x * 0.6 + sin(p.y * 0.3) * 2.0) * 0.5 + 0.5;
        float ripple = sin((p.x + p.y * 0.4) * 12.0) * 0.5 + 0.5;
        color = mix(float3(0.85, 0.7, 0.45), float3(0.95, 0.82, 0.55), dune) * (0.9 + 0.1 * ripple);
    } else if (kind == EnvironmentBeach) {
        // Sand near, the sea beyond a line ahead, with ripples that move.
        float shore = -3.0;
        if (world.z < shore) {
            float wave = sin((world.z - time * 0.8) * 2.0) * 0.5 + 0.5;
            float ripple = fbm(p * 1.5 + float2(time * 0.2, time * 0.1));
            color = mix(float3(0.05, 0.35, 0.5), float3(0.2, 0.6, 0.7), wave * 0.5 + ripple * 0.5);
            float foam = smoothstep(0.9, 1.0, sin((world.z - time * 0.8) * 2.0) * 0.5 + 0.5) * smoothstep(shore - 1.5, shore, world.z);
            color = mix(color, float3(0.95), foam);
        } else {
            color = mix(float3(0.9, 0.82, 0.65), float3(0.8, 0.72, 0.55), fbm(p * 3.0));
            color = mix(color, float3(0.6, 0.55, 0.45), smoothstep(shore + 1.0, shore, world.z));
        }
    } else if (kind == EnvironmentRuins) {
        float2 g = abs(fract(p * 0.9) - 0.5);
        float gap = smoothstep(0.42, 0.46, max(g.x, g.y));
        color = mix(float3(0.6, 0.57, 0.5) * (0.85 + 0.15 * hash21(floor(p * 0.9))), float3(0.2, 0.3, 0.12), gap);
    } else if (kind == EnvironmentCity) {
        float2 g = abs(fract(p * 0.5) - 0.5);
        float line = smoothstep(0.47, 0.5, max(g.x, g.y));
        float puddle = smoothstep(0.55, 0.7, fbm(p * 0.7));
        color = mix(float3(0.08, 0.08, 0.1), float3(0.15, 0.1, 0.25), puddle) + line * float3(0.9, 0.3, 0.8) * (0.3 + night);
    } else if (kind == EnvironmentMoon) {
        float n = fbm(p * 1.2);
        color = float3(0.5) * (0.6 + 0.4 * n);
        float crater = smoothstep(0.75, 0.85, fbm(p * 0.4 + 3.0));
        color *= 1.0 - crater * 0.5;
    } else {
        float n = fbm(p * 1.0);
        color = mix(float3(0.6, 0.3, 0.15), float3(0.8, 0.45, 0.25), n);
        color = mix(color, float3(0.4, 0.2, 0.1), smoothstep(0.7, 0.85, fbm(p * 0.3 + 11.0)));
    }
    float light = kind == EnvironmentMoon ? 1.0 : mix(1.0, 0.15, night);
    color *= light;
    float3 horizon = kind == EnvironmentMoon ? float3(0.0) : mix(float3(0.8, 0.85, 0.9), float3(0.03, 0.04, 0.08), night);
    float fog = 1.0 - exp(-distance * (kind == EnvironmentMoon ? 0.004 : 0.02));
    return float4(mix(color, horizon, fog * fog), 1.0);
}

// One-metre cells of neon on near-black, fading to the horizon's glow in the distance.
fragment float4 floorFragment(SceneOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]]) {
    if (frame.environment != EnvironmentSynthwave) {
        return placeFloor(in.worldPos, frame.eyes[in.eye].eyePosition.xyz, frame.environment, frame.night, frame.time);
    }
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
    float2 uv;
};

vertex OverlayOut overlayVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                                const device OverlayVertex *vertices [[buffer(1)]],
                                constant FrameUniforms &frame [[buffer(0)]]) {
    OverlayVertex v = vertices[vid];
    OverlayOut out;
    out.position = frame.eyes[amp].viewProjection * float4(v.position, 1);
    out.layer = 0;
    out.color = v.color;
    out.uv = v.uv;
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

// ---- Lit meshes (the games) ----------------------------------------------------------------

struct MeshOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
    float3 worldPos;
    float3 normal;
    float2 uv;
    float4 color;
    float4 material;    // roughness, metallic, emissive, pattern
    ushort eye [[flat]];
};

vertex MeshOut meshVertex(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                          const device MeshVertex *vertices [[buffer(1)]],
                          constant FrameUniforms &frame [[buffer(0)]],
                          constant MeshInstance &instance [[buffer(3)]]) {
    MeshVertex v = vertices[vid];
    float4 world = instance.model * float4(v.position, 1);
    MeshOut out;
    out.position = frame.eyes[amp].viewProjection * world;
    out.layer = 0;
    out.worldPos = world.xyz;
    out.normal = normalize((instance.model * float4(v.normal, 0)).xyz);
    out.uv = v.uv;
    out.color = instance.color;
    out.material = float4(instance.roughness, instance.metallic, instance.emissive, instance.pattern);
    out.eye = amp;
    return out;
}

// Blinn-Phong with a hemisphere ambient, a rim, a procedural surface pattern and a little
// Fresnel: enough to make a ball look like a ball and a toy look painted.
fragment float4 meshFragment(MeshOut in [[stage_in]], constant FrameUniforms &frame [[buffer(0)]],
                             constant LightUniforms &light [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float3 eye = frame.eyes[in.eye].eyePosition.xyz;
    float3 v = normalize(eye - in.worldPos);
    float3 l = normalize(light.lightDirection.xyz);
    float roughness = clamp(in.material.x, 0.05, 1.0);
    float metallic = in.material.y;
    float3 base = in.color.rgb;
    int pattern = int(in.material.w + 0.5);
    if (pattern == 9) {            // a blob shadow: a soft dark disc, no lighting
        float r = length(in.uv - 0.5) * 2.0;
        return float4(0.0, 0.0, 0.0, in.color.a * (1.0 - smoothstep(0.55, 1.0, r)));
    }
    if (pattern == 1) {            // dimples
        float2 g = fract(in.uv * float2(24.0, 12.0)) - 0.5;
        base *= 1.0 - 0.25 * (1.0 - smoothstep(0.2, 0.35, length(g)));
    } else if (pattern == 2) {     // stripes
        base = mix(base, base * 0.35 + 0.1, step(0.5, fract(in.uv.y * 8.0)));
    } else if (pattern == 3) {     // checks
        float c = step(0.5, fract(in.uv.x * 8.0)) + step(0.5, fract(in.uv.y * 8.0));
        base = mix(base, float3(1.0) - base * 0.3, fmod(c, 2.0));
    } else if (pattern == 4) {     // scales
        float2 g = fract(in.uv * float2(18.0, 9.0) + float2(step(0.5, fract(in.uv.y * 4.5)) * 0.5, 0.0)) - 0.5;
        base *= 0.85 + 0.15 * smoothstep(0.45, 0.3, length(g));
    } else if (pattern == 5) {     // noise
        base *= 0.8 + 0.2 * fbm(in.uv * 12.0);
    }
    float3 h = normalize(l + v);
    float ndl = max(dot(n, l), 0.0);
    float ndh = max(dot(n, h), 0.0);
    float shininess = mix(96.0, 4.0, roughness);
    float spec = pow(ndh, shininess) * (1.0 - roughness * 0.7);
    float fresnel = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    float3 ambient = mix(light.groundColor.rgb, light.skyColor.rgb, n.y * 0.5 + 0.5);
    float3 diffuse = base * (ambient * 0.6 + light.lightColor.rgb * ndl) * (1.0 - metallic * 0.6);
    float3 specular = mix(float3(1.0), base, metallic) * light.lightColor.rgb * spec * (0.3 + metallic * 0.7);
    float3 rim = base * fresnel * 0.25;
    float3 color = diffuse + specular + rim + base * in.material.z;
    return float4(color, in.color.a);
}

// Additive sprites (sparks, trails, glows): the overlay's vertices, blended by adding.
fragment float4 glowFragment(OverlayOut in [[stage_in]]) {
    // A soft radial falloff across the sprite (uv 0..1), brightest at the centre.
    float r = length(in.uv - 0.5) * 2.0;
    float a = in.color.a * pow(saturate(1.0 - r), 2.0);
    return float4(in.color.rgb * a, a);
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
    // The panels' pictures are premultiplied with transparent corners; the page is opaque.
    return float4(c.rgb * tint.rgb, c.a * tint.a);
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
