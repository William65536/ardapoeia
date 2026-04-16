struct VertexIn {
    @location(0) pos: vec3f,
    @location(1) normal: vec3f,
}

struct VertexOut {
    @builtin(position) pos: vec4f,
    @location(0) world_pos: vec3f,
    @location(1) normal: vec3f,
}

struct WindowInput {
    cursor_pos: vec2f,
}

struct Camera {
    view: mat4x4f,
    proj: mat4x4f,
}

@group(0) @binding(0)
var<uniform> camera: Camera;

@vertex
fn vsMain(in: VertexIn) -> VertexOut {
    var out: VertexOut;
    out.pos = camera.proj * camera.view * vec4(in.pos, 1.0);
    out.world_pos = in.pos;
    out.normal = in.normal;
    return out;
}

@fragment
fn fsMain(out: VertexOut) -> @location(0) vec4f {
    let base_color = vec4((out.normal + 1.0) * 0.5, 1.0);

    let isoline_color = vec4(0.75, 0.75, 0.75, 1.0);
    let thickness = 2.0;
    let interval = 100.0;
    let world_y = out.world_pos.y / interval;
    let px_width = fwidth(world_y);
    let dist = abs(fract(world_y - 0.5) - 0.5);
    let isoline = smoothstep(thickness * 0.5 * px_width, 0.0, dist);

    return mix(base_color, isoline_color, isoline);
}
