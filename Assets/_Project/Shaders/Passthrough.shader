// The passthrough screen: the camera image, reprojected onto a quad in front of the eyes. It's the
// background, so it draws first, ignores depth and writes none, and everything virtual draws over it
// wherever it is. The render state is fixed here rather than in material properties, which URP resets
// from the surface type. It has only a forward pass: a depth-only pass would put the quad in URP's
// depth prepass and cut through virtual things behind it.
//
// The quad is not the picture; it is only the surface that gets these pixels drawn. What each pixel
// shows is decided from the direction it looks in and nothing else: the direction from the eye to
// the fragment is turned into the axes of the camera that took the image, and that direction says
// where in the image to sample. Depth drops out, and so does where the head is -- only which way it
// faces can move the picture. See PassthroughController for why that matters.
Shader "Afterglow/Passthrough"
{
    Properties
    {
        [MainTexture] _BaseMap ("Camera Image", 2D) = "black" {}
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
            "Queue" = "Background"
        }

        Pass
        {
            Name "Passthrough"
            Tags { "LightMode" = "UniversalForward" }

            Cull Off
            ZWrite Off
            ZTest Always

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                // World space into the axes of the camera that took this image: x right, y up,
                // z forward, as Unity holds a camera's own space. Only its rotation is used, since
                // what is reprojected is a direction.
                float4x4 _CaptureFromWorld;
                // What the image covers in those axes at unit distance: center.xy, size.xy. Zero
                // size means no image has arrived yet.
                float4 _CaptureFrustum;
            CBUFFER_END

            struct Attributes
            {
                float3 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(output.positionWS);
                return output;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                // w = 0: a direction, from the eye, so the translation column is left out of it.
                // _WorldSpaceCameraPos is this eye's own, so each eye asks from where it really is.
                float3 toPixel = input.positionWS - _WorldSpaceCameraPos;
                float3 inCamera = mul(_CaptureFromWorld, float4(toPixel, 0.0)).xyz;
                float2 size = _CaptureFrustum.zw;
                // No image yet, or this pixel looks behind the camera that took the one there is.
                clip(min(min(size.x, size.y), inCamera.z) - 1e-6);
                float2 uv = (inCamera.xy / inCamera.z - _CaptureFrustum.xy) / size + 0.5;
                // Outside what the camera saw. The camera sees less than a Cardboard eye, so the
                // picture is a window: dropping these pixels leaves the view's own background around
                // it, which is the dark border the smaller quad used to leave.
                clip(min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
                return half4(SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv).rgb, 1.0);
            }
            ENDHLSL
        }
    }
}
