// Types shared between the Swift renderer and the Metal shaders.
#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// One eye's view. The scene pass draws both eyes in one draw with vertex amplification, indexing
// this by the amplification id.
typedef struct {
    matrix_float4x4 viewProjection;      // world -> clip
    matrix_float4x4 inverseProjection;   // clip -> view, for direction-per-pixel passes
    matrix_float4x4 worldFromView;       // the eye's rotation and position in the world
    vector_float4 eyePosition;           // the eye in the world
} EyeUniforms;

typedef struct {
    EyeUniforms eyes[2];
    // Passthrough: the rotation from the world into the axes of the camera that took the image
    // (x right, y up, -z forward), and the image's intrinsics as fractions of its size:
    // (fx / width, fy / height, cx / width, cy / height).
    matrix_float4x4 captureFromWorld;
    vector_float4 captureIntrinsics;
    float time;                          // seconds since launch, for the environment's animation
    float floorHeight;                   // the virtual floor's y
    float passthroughBlend;              // 1 shows the camera image, 0 the surroundings
    float captureVideoRange;             // 1 when the image's samples are video range (Y 16-235)
} FrameUniforms;

typedef struct {
    vector_float2 position;              // NDC over the whole screen
    vector_float2 uv;                    // eye texture UV, origin bottom left
    unsigned int eye;
} DistortionVertex;

// Media projections: how a picture or video wraps around the viewer. One shader draws every
// kind from a direction per pixel; `layout` says where each eye's picture sits in the texture.
typedef enum {
    MediaProjectionFlat = 0,          // a flat screen ahead (handled by the quad pipeline)
    MediaProjectionEquirect360 = 1,   // the whole sphere, longitude across, latitude down
    MediaProjectionEquirect180 = 2,   // the front hemisphere, 180 degrees across
    MediaProjectionFisheye180 = 3,    // an equidistant fisheye circle, 180 degrees
    MediaProjectionCylinder = 4,      // a panorama band: `span` radians across, `height` tall
} MediaProjection;

typedef enum {
    MediaLayoutMono = 0,              // one picture for both eyes
    MediaLayoutSideBySide = 1,        // left eye on the left half, right eye on the right
    MediaLayoutTopBottom = 2,         // left eye on top, right eye below
    MediaLayoutArray = 3,             // one picture per slice of a texture array (spatial media)
} MediaLayout;

typedef struct {
    int projection;                   // MediaProjection
    int layout;                       // MediaLayout
    float span;                       // cylinder: radians across; 180/fisheye: field in radians
    float height;                     // cylinder: half-height over radius (tan of the half angle)
    float yaw;                        // where the picture's centre faces, radians
    float brightness;
    int swapEyes;                     // 1 when the halves are the other way round
    int pad;
} MediaUniforms;

// A detected surface's mesh: world position and the point's place on the plane (metres from
// the plane's centre along its own axes), for the marks and the edge fade.
typedef struct {
    vector_float3 position;
    vector_float2 local;
    vector_float2 extent;             // the plane's half extents, for fading its edges
} SurfaceVertex;

typedef struct {
    vector_float4 color;
    vector_float4 highlightColor;
    vector_float4 gazePoint;          // world, w = 1 when the gaze is on a surface
    float appear;                     // 0..1 as surfaces fade in or out
    float spacing;                    // metres between marks
    float time;
    float pad;
} SurfaceUniforms;

// Textured quads in the world (the browser window, panels): position and texture coordinate.
typedef struct {
    vector_float3 position;
    vector_float2 uv;
} QuadVertex;

// Hands and demo objects: world-space triangles with a colour each.
typedef struct {
    vector_float3 position;
    vector_float4 color;
} OverlayVertex;

#endif
