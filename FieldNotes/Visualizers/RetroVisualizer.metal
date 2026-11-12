#include <metal_stdlib>
using namespace metal;

struct RetroVertex {
    float4 position [[position]];
    float2 uv;
};

struct RetroFrame {
    float time;
    float aspect;
    float level;
    float bass;
    uint waveformCount;
    uint hasHistory;
    float motion;
    float frameStep;
};

vertex RetroVertex retroVertex(uint vertexID [[vertex_id]]) {
    const float2 corners[] = { float2(-1, 1), float2(-1, -3), float2(3, 1) };
    float2 position = corners[vertexID];
    return { float4(position, 0, 1), position * float2(0.5, -0.5) + 0.5 };
}

static float2 rotateRetro(float2 point, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * point.x - s * point.y, s * point.x + c * point.y);
}

static float3 retroPalette(float time) {
    const float3 colors[] = {
        float3(0.025, 0.12, 0.95),
        float3(0.72, 0.025, 0.86),
        float3(0.10, 0.78, 0.065),
        float3(0.025, 0.12, 0.95)
    };
    float phase = fract(time / 15.0) * 3.0;
    uint index = min(uint(phase), 2u);
    return mix(colors[index], colors[index + 1], smoothstep(0.2, 0.87, fract(phase)));
}

fragment half4 retroFeedback(
    RetroVertex in [[stage_in]],
    texture2d<half> history [[texture(0)]],
    constant RetroFrame &frame [[buffer(0)]],
    constant float *waveform [[buffer(1)]]
) {
    constexpr sampler historySampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float2 aspect = float2(frame.aspect, 1.0);
    float2 point = (in.uv - 0.5) * aspect;
    float radius = length(point);
    float3 light = 0.0;

    if (frame.hasHistory) {
        // Inverse zoom and twist make the last image expand and curl away from the middle.
        float angle = (0.022 + 0.055 * frame.bass) * (1.0 - min(radius, 1.0));
        angle *= sin(frame.time * 0.8 + radius * 2.8) * frame.frameStep;
        float zoom = 1.0 - (0.023 + 0.045 * frame.bass) * frame.frameStep;
        float2 previousUV = rotateRetro(point, angle) * zoom / aspect + 0.5;
        light = float3(history.sample(historySampler, previousUV).rgb) * pow(0.90, frame.frameStep);
    }

    if (frame.waveformCount > 1 && frame.level > 0.001) {
        float tilt = (0.53 * sin(frame.time * 0.51) + 0.18 * sin(frame.time * 0.94)) * frame.motion;
        float2 lane = rotateRetro(point, tilt);
        float x = lane.x / frame.aspect + 0.5;
        float position = saturate(x) * float(frame.waveformCount - 1);
        uint index = uint(position);
        float sample = mix(waveform[index], waveform[min(index + 1, frame.waveformCount - 1)], fract(position));

        float bend = 0.058 * cos(lane.x * 6.0 + frame.time * 0.71) * frame.motion;
        float separation = 0.14 + 0.083 * frame.bass + bend;
        float distance = abs(abs(lane.y) - separation - sample * (0.05 + 0.10 * frame.level));
        float core = exp(-distance * distance / 0.000027);
        float ribbon = exp(-distance * distance / 0.00048);
        float halo = exp(-distance * distance / 0.008);
        float edge = 1.0 - smoothstep(0.36, 0.5, abs(x - 0.5));
        float3 tint = retroPalette(frame.time);
        float3 white = mix(tint, float3(0.86, 0.95, 1.0), 0.72);
        float3 traces = edge * (white * (0.69 * core) + tint * (0.37 * ribbon + 0.12 * halo));

        float ringDistance = abs(radius - (0.09 + 0.14 * frame.bass));
        float ring = exp(-ringDistance * ringDistance / 0.0028);
        float ringLight = 0.12 * frame.bass * ring * frame.motion;
        float emissionStep = frame.motion > 0.0 ? frame.frameStep : 1.0;
        light += frame.level * (traces + tint * ringLight) * emissionStep;
    }

    return half4(half3(min(light, 3.0)), 1.0h);
}

fragment half4 retroPresent(RetroVertex in [[stage_in]], texture2d<half> image [[texture(0)]]) {
    constexpr sampler imageSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 light = float3(image.sample(imageSampler, in.uv).rgb);
    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = 1.0 - 0.38 * smoothstep(0.25, 1.4, length(centered));
    float3 background = float3(0.004, 0.005, 0.017) + float3(0.003, 0.006, 0.018) * vignette;
    float3 mapped = 1.0 - exp(-1.55 * light);
    return half4(half3(background + mapped * vignette), 1.0h);
}
