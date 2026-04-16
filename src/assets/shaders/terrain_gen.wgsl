struct HeightmapParams {
    width: u32,
    height: u32,
    elev_min: f32,
    elev_max: f32,
};

@group(0) @binding(0)
var heightmap: texture_2d<u32>;
@group(1) @binding(0)
var<uniform> hp: HeightmapParams;
@group(2) @binding(0)
var<storage, read_write> vertices: array<f32>;

const m_per_px = 30;

fn getHeight(ix: i32, iy: i32) -> f32 {
    let x = clamp(ix, 0, i32(hp.width) - 1);
    let y = clamp(iy, 0, i32(hp.height) - 1);

    let raw = textureLoad(heightmap, vec2(u32(x), u32(y)), 0).r;
    return f32(raw) / 65534.0 * (hp.elev_max - hp.elev_min) + hp.elev_min;
}

@compute @workgroup_size(16, 16)
fn genVertices(@builtin(global_invocation_id) id: vec3u) {
    if hp.width <= id.x || hp.height <= id.y {
        return;
    }

    let x = i32(id.x);
    let y = i32(id.y);

    let h = getHeight(x, y);

    let h_l = getHeight(x - 1, y);
    let h_r = getHeight(x + 1, y);
    let h_b = getHeight(x, y - 1);
    let h_t = getHeight(x, y + 1);

    // Derivative calculations are incorrect for edges;
    // multiplication by 2.0 should be removed, but this is ignored
    let dx = (h_r - h_l) / (2.0 * f32(m_per_px));
    let dz = (h_t - h_b) / (2.0 * f32(m_per_px));

    let pos = vec3(f32(id.x) * f32(m_per_px), h, f32(id.y) * f32(m_per_px));

    let normal = normalize(vec3(-dx, 1.0, -dz));

    let i = (id.y * hp.width + id.x) * 6;

    vertices[i + 0] = pos.x;
    vertices[i + 1] = pos.y;
    vertices[i + 2] = pos.z;
    vertices[i + 3] = normal.x;
    vertices[i + 4] = normal.y;
    vertices[i + 5] = normal.z;
}

@group(2) @binding(1)
var<storage, read_write> indices: array<u32>;

@compute @workgroup_size(16, 16)
fn genIndices(@builtin(global_invocation_id) id: vec3u) {
    if hp.width - 1 <= id.x || hp.height - 1 <= id.y {
        return;
    }

    let v_00 = id.y * hp.width + id.x;
    let v_10 = v_00 + 1;
    let v_01 = v_00 + hp.width;
    let v_11 = v_01 + 1;

    let i = (id.y * (hp.width - 1) + id.x) * 6;
    indices[i + 0] = v_00;
    indices[i + 1] = v_10;
    indices[i + 2] = v_11;
    indices[i + 3] = v_11;
    indices[i + 4] = v_01;
    indices[i + 5] = v_00;
}
