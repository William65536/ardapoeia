struct VertexIn {
    @location(0) pos: vec2f,
    @location(1) color: vec3f,
}

struct VertexOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec3f,
}

@vertex
fn vsMain(in: VertexIn) -> VertexOut {
    var out: VertexOut;
    out.pos = vec4f(in.pos, 0.0, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fsMain(out: VertexOut) -> @location(0) vec4f {
    return vec4(out.color, 1.0);
}
