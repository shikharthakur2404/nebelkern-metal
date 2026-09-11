// ─────────────────────────────────────────────────────────────────────────────
// Shaders.metal — Native Metal Shading Language Pipeline for nebelkern-metal
//
// 1. 3D Curl Noise Compute Kernel (GPU Particle Advection)
// 2. High-Precision Perspective Vertex Shader
// 3. Gaussian Exponential Falloff Fragment Shader with EDR/HDR Lum Boost
// 4. Persistence Accumulation Blend Shader for Motion Trails
// ─────────────────────────────────────────────────────────────────────────────

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// ── Shared Data Structures ───────────────────────────────────────────────────

struct Particle {
    packed_float3 position;
    packed_float3 basePosition;
    packed_float3 velocity;
    float         scale;
    float         luminance;
    float         seed;
    float         padding;
};

struct Uniforms {
    float        time;
    float        dispersion;
    float        noiseScale;
    float        noiseSpeed;
    float        trailDamp;
    float        peakLuminance; // > 1.0 on Apple Silicon Liquid Retina XDR
    simd_float3  colorCore;
    simd_float3  colorMid;
    simd_float3  colorOuter;
    simd_float2  viewportSize;
};

struct VertexOut {
    float4 position   [[position]];
    float  pointSize  [[point_size]];
    float  luminance;
};

// ── 3D Simplex & Curl Noise Implementation in MSL ───────────────────────────

static float3 mod289(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

static float4 mod289(float4 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

static float4 permute(float4 x) {
    return mod289(((x * 34.0) + 1.0) * x);
}

static float4 taylorInvSqrt(float4 r) {
    return 1.79284291400159 - 0.85373472095314 * r;
}

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);

    float3 i  = floor(v + dot(v, float3(C.y)));
    float3 x0 = v - i + dot(i, float3(C.x));

    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.x;
    float3 x2 = x0 - i2 + C.y;
    float3 x3 = x0 - D.yyy;

    i = mod289(i);
    float4 p = permute(permute(permute(
        i.z + float4(0.0, i1.z, i2.z, 1.0))
        + i.y + float4(0.0, i1.y, i2.y, 1.0))
        + i.x + float4(0.0, i1.x, i2.x, 1.0));

    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;

    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);

    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// Compute 3D Curl (divergence-free velocity field)
static float3 computeCurl(float3 p) {
    const float e = 0.08;
    float n1 = snoise(float3(p.x, p.y + e, p.z));
    float n2 = snoise(float3(p.x, p.y - e, p.z));
    float n3 = snoise(float3(p.x, p.y, p.z + e));
    float n4 = snoise(float3(p.x, p.y, p.z - e));
    float n5 = snoise(float3(p.x + e, p.y, p.z));
    float n6 = snoise(float3(p.x - e, p.y, p.z));

    float dFz_dy = (n1 - n2) / (2.0 * e);
    float dFy_dz = (n3 - n4) / (2.0 * e);
    float dFx_dz = (n3 - n4) / (2.0 * e);
    float dFz_dx = (n5 - n6) / (2.0 * e);
    float dFy_dx = (n5 - n6) / (2.0 * e);
    float dFx_dy = (n1 - n2) / (2.0 * e);

    return float3(dFz_dy - dFy_dz, dFx_dz - dFz_dx, dFy_dx - dFx_dy);
}

// ── 1. Compute Kernel: Particle Advection & Curl Flow ────────────────────────

kernel void updateParticles(
    device Particle*         particles [[buffer(0)]],
    constant Uniforms&       uniforms  [[buffer(1)]],
    uint                     id        [[thread_position_in_grid]]
) {
    Particle p = particles[id];

    float3 base = float3(p.basePosition);
    float3 samplePos = base * uniforms.noiseScale + float3(uniforms.time * uniforms.noiseSpeed * 0.15);
    float3 curl = computeCurl(samplePos);

    // Target displaced position based on curl noise and dispersion
    float3 target = base + curl * uniforms.dispersion * 0.65;

    // Outward radial expansion when dispersion increases
    float radial = length(base.xy);
    target.xy += normalize(base.xy + float2(0.0001)) * radial * uniforms.dispersion * 0.08;

    // Sub-pixel micro-jitter to prevent moiré & sub-pixel aliasing
    float jitterSeed = p.seed * 100.0 + uniforms.time * 60.0;
    float2 jitter = float2(sin(jitterSeed * 12.9898), cos(jitterSeed * 78.233)) * 0.002;
    target.xy += jitter;

    // Smooth temporal lerp on GPU
    float3 current = float3(p.position);
    p.position = packed_float3(current + (target - current) * 0.12);

    particles[id] = p;
}

// ── 2. Vertex Shader ─────────────────────────────────────────────────────────

vertex VertexOut particleVertex(
    const device Particle* particles [[buffer(0)]],
    constant Uniforms&     uniforms  [[buffer(1)]],
    uint                   id        [[vertex_id]]
) {
    Particle p = particles[id];
    VertexOut out;

    float3 pos = float3(p.position);

    // Camera perspective transform
    float aspect = uniforms.viewportSize.x / max(uniforms.viewportSize.y, 1.0f);
    float zDist  = 3.2 - pos.z;
    float fovScale = 1.8 / zDist;

    out.position = float4(pos.x * fovScale / aspect, pos.y * fovScale, pos.z * 0.1, 1.0);

    // Perspective point size + luminance boost
    float baseSize = p.scale * (uniforms.viewportSize.y / 700.0) * (6.0 / zDist);
    out.pointSize = max(baseSize * (0.6 + p.luminance * 0.9), 1.5f);
    out.luminance = p.luminance;

    return out;
}

// ── 3. Fragment Shader: Gaussian Optical Glow & EDR HDR Luminance ────────────

fragment float4 particleFragment(
    VertexOut         in        [[stage_in]],
    float2            pointUv   [[point_coord]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    float2 uv = pointUv - float2(0.5);
    float dist = length(uv);

    if (dist > 0.5) {
        discard_fragment();
    }

    // Gaussian exponential falloff: alpha = exp(-k * d^2)
    float k = 8.0 + in.luminance * 14.0;
    float alpha = exp(-k * dist * dist * 4.0);

    // Color temperature ramp: outer -> mid -> core
    float3 col = mix(uniforms.colorOuter, uniforms.colorMid, smoothstep(0.0, 0.45, in.luminance));
    col = mix(col, uniforms.colorCore * uniforms.peakLuminance, smoothstep(0.40, 0.95, in.luminance));

    // Chromatic fringe dispersion on particle boundary
    float fringe = smoothstep(0.32, 0.48, dist);
    col.r += fringe * 0.15;
    col.b += fringe * 0.25;

    // Premultiplied alpha for additive blending
    return float4(col * alpha, alpha * (0.7 + in.luminance * 0.3));
}

// ── 4. Full-Screen Trail Persistence Accumulation Shader ─────────────────────

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreenVertex(uint id [[vertex_id]]) {
    FullscreenVertexOut out;
    float2 uv = float2((id << 1) & 2, id & 2);
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

fragment float4 trailAccumFragment(
    FullscreenVertexOut in       [[stage_in]],
    texture2d<float>    tCurrent [[texture(0)]],
    texture2d<float>    tHistory [[texture(1)]],
    constant Uniforms&  uniforms [[buffer(1)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 cur = tCurrent.sample(s, in.uv);
    float4 hist = tHistory.sample(s, in.uv);

    float4 decayed = hist * uniforms.trailDamp;
    decayed *= step(0.01, max(decayed.r, max(decayed.g, decayed.b)));

    return max(cur, decayed);
}
