#include <metal_stdlib>
using namespace metal;

// ====== Shared structs ======
struct StrokeVSIn {
    float2 pos      [[attribute(0)]];
    float  edgeDist [[attribute(1)]];
};

struct StrokeVSOut {
    float4 position [[position]];
    float  edgeDist;
};

struct ViewUniforms {
    float2 vpSize;   // viewport (pixels)
    float2 offset;   // pixel offset AFTER scaling
    float  scale;    // uniform scale
    float  _pad;
};

// ====== Stroke pass ======
vertex StrokeVSOut stroke_vs(StrokeVSIn in [[stage_in]],
                             constant ViewUniforms& U [[buffer(1)]])
{
    // Pixel-space -> scale & offset
    float2 P = in.pos * U.scale + U.offset;

    // Pixel -> clip (flip Y)
    float2 ndc;
    ndc.x = (P.x / U.vpSize.x) * 2.0 - 1.0;
    ndc.y = (1.0 - P.y / U.vpSize.y) * 2.0 - 1.0;

    StrokeVSOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.edgeDist = in.edgeDist;
    return out;
}

fragment half4 stroke_fs(StrokeVSOut in [[stage_in]],
                         constant float3& neonColor [[buffer(0)]])
{
    // edgeDist is 0 at the centre line and 1 at the outer edge.
    float t = clamp(1.0 - in.edgeDist, 0.0, 1.0);
    float core = pow(t, 3.0); // bright core with soft falloff
    return half4(half3(neonColor) * core, core);
}

// ====== Fullscreen composite ======
struct FSQ {
    float4 position [[position]];
    float2 uv;
};

vertex FSQ fullscreen_vs(uint vid [[vertex_id]])
{
    const float2 pos[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    const float2 uv_[3] = { float2(0,0),   float2(2,0),  float2(0,2)  };
    FSQ o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = uv_[vid];
    return o;
}

fragment half4 composite_fs(FSQ in [[stage_in]],
                            texture2d<float> strokeTex [[texture(0)]],
                            texture2d<float> glowTex   [[texture(1)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 stroke = strokeTex.sample(s, in.uv).rgb;
    float3 glow   = glowTex.sample(s, in.uv).rgb;
    float3 rgb = clamp(stroke + glow, 0.0, 1.0);
    return half4(half3(rgb), 1.0);
}

// ====== Simple blur (optional) ======
kernel void blur_simple(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float3 sum = float3(0);
    int taps = 0;
    for (int dy=-2; dy<=2; ++dy) {
        for (int dx=-2; dx<=2; ++dx) {
            int x = clamp(int(gid.x)+dx, 0, int(W)-1);
            int y = clamp(int(gid.y)+dy, 0, int(H)-1);
            sum += src.read(uint2(x,y)).rgb;
            taps++;
        }
    }
    float3 avg = sum / float(taps);
    dst.write(float4(avg,1), gid);
}
