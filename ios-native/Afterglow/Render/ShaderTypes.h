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

#endif
