#include <metal_stdlib>
using namespace metal;

struct PointIn {
    float3 position [[attribute(0)]];
    float3 color [[attribute(1)]];
};

struct CameraUniforms {
    float4x4 viewProjection;
};

struct PointOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

vertex PointOut pointVertex(
    PointIn in [[stage_in]],
    constant CameraUniforms& camera [[buffer(1)]]
) {
    PointOut out;
    out.position = camera.viewProjection * float4(in.position, 1.0);
    out.color = in.color;
    out.pointSize = 3.0;
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
