struct Camera {
    view_proj: mat4x4f,
}

struct LodLeaf {
    origin: vec2f,
    data: u32,
    sample_slot: u32,
}

struct HeightSample {
    normal: vec3f,
    height: f32,
}

struct VertexIn {
    @builtin(vertex_index) vert_idx: u32,
    @builtin(instance_index) inst_idx: u32,
}

struct VertexOut {
    @builtin(position) pos: vec4f,
    @location(0) world_pos: vec3f,
    @location(1) normal: vec3f,
}

const pi = 0.5 * radians(180.0);

@group(0) @binding(0)
var<uniform> camera: Camera;
@group(1) @binding(0)
var<storage, read> lod_leaves: array<LodLeaf>;
@group(2) @binding(0)
var<storage, read> height_samples: array<HeightSample>;

const lod_leaf_extent_span = 32; // must be power of 2
const lod_base_extent = 0.0625; // must be power of 2

const height_samples_per_leaf =
    (lod_leaf_extent_span + 1) * (lod_leaf_extent_span + 1);

@vertex
fn vsMain(in: VertexIn) -> VertexOut {
    let leaf = lod_leaves[in.inst_idx];

    let level = leaf.data & 0x1f;

    let edge_n = (leaf.data >> 5) & 0x1f;
    let edge_w = (leaf.data >> 10) & 0x1f;
    let edge_s = (leaf.data >> 15) & 0x1f;
    let edge_e = (leaf.data >> 20) & 0x1f;

    let unit = lod_base_extent * f32(1 << level);

    let offset = leaf.origin - vec2(0.5) * f32(lod_leaf_extent_span) * unit;

    let grid_x = in.vert_idx % (lod_leaf_extent_span + 1);
    let grid_z = in.vert_idx / (lod_leaf_extent_span + 1);

    var snapped_x = grid_x;
    var snapped_z = grid_z;

    // Snap odd vertices on flagged edges to even neighbors
    // TODO: Take into account level delta; currently assumed to be 1
    if (edge_n > 0 && grid_z == lod_leaf_extent_span && (grid_x & 1) > 0) {
        snapped_x = grid_x - 1;
    }
    if (edge_s > 0 && grid_z == 0 && (grid_x & 1) > 0) {
        snapped_x = grid_x - 1;
    }
    if (edge_e > 0 && grid_x == lod_leaf_extent_span && (grid_z & 1) > 0) {
        snapped_z = grid_z - 1;
    }
    if (edge_w > 0 && grid_x == 0 && (grid_z & 1) > 0) {
        snapped_z = grid_z - 1;
    }

    let world_x = f32(snapped_x) * unit + offset.x;
    let world_z = f32(snapped_z) * unit + offset.y;
    let sample_idx =
        leaf.sample_slot * height_samples_per_leaf +
        snapped_z * (lod_leaf_extent_span + 1) + snapped_x;
    let sample = height_samples[sample_idx];
    let world_y = sample.height;
    let world_pos = vec3(world_x, world_y, world_z);

    var out: VertexOut;
    out.pos = camera.view_proj * vec4(world_pos, 1.0);
    out.world_pos = world_pos;
    out.normal = sample.normal;
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
