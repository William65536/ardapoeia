struct Input {
    cursor_pos: vec2u,
};

@group(0) @binding(0)
var<uniform> input: Input;
@group(1) @binding(0)
var depth: texture_depth_2d;
@group(2) @binding(0)
var<storage, read_write> depth_sample: f32;

@compute @workgroup_size(1, 1)
fn sampleDepth() {
    depth_sample = textureLoad(depth, input.cursor_pos, 0);
}
