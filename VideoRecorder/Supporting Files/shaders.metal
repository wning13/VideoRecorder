//
//  shaders.metal
//  VideoRecorder
//
//  Created by 王宁 on 2019/11/12.
//  Copyright © 2019 王宁. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

typedef struct {
    vector_float4 position;
    vector_float2 textureCoordinate;
} SceneVertex;

typedef struct {
    vector_float4 position;
    vector_float4 color;
} Vertex;

typedef struct
{
    float4 clipSpacePosition [[position]];
    float4 color;
    float2 textureCoordinate;
    
} RasterizerData;

vertex RasterizerData vertexShader(uint vertexID [[ vertex_id ]],
                                   constant SceneVertex *vertexArray [[ buffer(0) ]]) {
    RasterizerData out;
    out.clipSpacePosition = vertexArray[vertexID].position;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    return out;
}

fragment float4 samplingShader(RasterizerData input [[stage_in]],
                               texture2d<half> colorTexture [[ texture(0) ]])
{
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    half4 colorSample = colorTexture.sample(textureSampler, input.textureCoordinate);
    
    return float4(colorSample);
}

fragment float4 videoSamplingShader(RasterizerData input [[stage_in]],
                                    texture2d<float> textureY [[ texture(0) ]],
                                    texture2d<float> textureUV [[ texture(1) ]])
{
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear); // sampler是采样器
    
//    float3 colorOffset = float3(-(16.0/255.0), -0.5, -0.5);
//    float3x3 colorMatrix = float3x3(
//                                    float3(1.164,  1.164, 1.164),
//                                    float3(0.000, -0.392, 2.017),
//                                    float3(1.596, -0.813, 0.000)
//                                    );
//
//    float3 yuv = float3(textureY.sample(textureSampler, input.textureCoordinate).r,
//                          textureUV.sample(textureSampler, input.textureCoordinate).rg);
//
//    float3 rgb = colorMatrix * (yuv + colorOffset);
//
//    return float4(rgb, 1.0);
    
    
    return float4(textureY.sample(textureSampler, input.textureCoordinate).b,
                  textureY.sample(textureSampler, input.textureCoordinate).g,
                  textureY.sample(textureSampler, input.textureCoordinate).r,
                  1.0
                  );
//
//    return float4(colorSample);

}


vertex RasterizerData paintVertexShader(uint vertexID [[ vertex_id ]],  constant Vertex *vertexArray [[ buffer(0) ]]) {
    RasterizerData out;
    out.clipSpacePosition = vertexArray[vertexID].position;
    out.color = vertexArray[vertexID].color;
    return out;
}

fragment float4 paintSamplingShader(RasterizerData input [[stage_in]], texture2d<half> textureColor [[ texture(0) ]]) {
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    half4 colorTex = half4(input.color.r, input.color.g, input.color.b, input.color.a);
    return float4(colorTex);
}
 
