struct LodLeaf {
    origin: vec2f,
    data: u32,
    sample_slot: u32,
}

struct HeightSample {
    normal: vec3f,
    height: f32,
}

@group(0) @binding(0)
var<storage, read> lod_leaves: array<LodLeaf>;
@group(1) @binding(0)
var<storage, read_write> height_samples: array<HeightSample>;

const lod_leaf_extent_span = 32; // must be power of 2
const lod_base_extent = 0.0625; // must be power of 2

const height_samples_per_leaf =
    (lod_leaf_extent_span + 1) * (lod_leaf_extent_span + 1);

@compute @workgroup_size(256, 1, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let local_idx = id.x;
    if (local_idx >= height_samples_per_leaf) {
        return;
    }
    let leaf_idx = id.y;

    let samples_per_leaf = u32((lod_leaf_extent_span + 1) * (lod_leaf_extent_span + 1));
    let grid_x = local_idx % u32(lod_leaf_extent_span + 1);
    let grid_z = local_idx / u32(lod_leaf_extent_span + 1);

    let leaf = lod_leaves[leaf_idx];
    let level = leaf.data & 0x1f;
    let unit = lod_base_extent * f32(1 << level);
    let offset = leaf.origin - vec2(0.5) * f32(lod_leaf_extent_span) * unit;

    let world_x = f32(grid_x) * unit + offset.x;
    let world_z = f32(grid_z) * unit + offset.y;

    let height = sampleHeight(world_x, world_z);
    let normal = computeNormal(world_x, world_z);

    let sample_idx = leaf.sample_slot * u32(height_samples_per_leaf) + local_idx;

    height_samples[sample_idx] = HeightSample(normal, height);
}

fn sampleHeight(x: f32, z: f32) -> f32 {
    let scale = 1.0 / 2048.0;
    var height = 0.0;
    height += noise(0, vec3f(x * scale, z * scale, 0.0)) * 400.0;
    height += noise(1, vec3f(x * scale * 2.0, z * scale * 2.0, 0.0)) * 200.0;
    height += noise(2, vec3f(x * scale * 4.0, z * scale * 4.0, 0.0)) * 100.0;
    height += noise(3, vec3f(x * scale * 8.0, z * scale * 8.0, 0.0)) * 50.0;
    height += noise(4, vec3f(x * scale * 16.0, z * scale * 16.0, 0.0)) * 25.0;
    return height;
}

fn computeNormal(x: f32, z: f32) -> vec3f {
    let h = 0.125;
    let dydx = (sampleHeight(x + h, z) - sampleHeight(x - h, z)) / (2.0 * h);
    let dydz = (sampleHeight(x, z + h) - sampleHeight(x, z - h)) / (2.0 * h);
    return normalize(vec3f(-dydx, 1.0, -dydz));
}

// Perlin's "Improved Noise" algorithm
fn noise(seed: u32, p: vec3f) -> f32 {
    let p_floor = bitcast<vec3u>(vec3i(floor(p)));

    let p_mod = p - floor(p);

    let p_smooth =
        vec3(smootherstep(p_mod.x), smootherstep(p_mod.y), smootherstep(p_mod.z));

    let a = hash32(seed, p_floor.x) + p_floor.y;
    let aa = hash32(seed, a) + p_floor.z;
    let ab = hash32(seed, a + 1) + p_floor.z;
    let b = hash32(seed, p_floor.x + 1) + p_floor.y;
    let ba = hash32(seed, b) + p_floor.z;
    let bb = hash32(seed, b + 1) + p_floor.z;

    let x0y0z0 = gradDot(hash32(seed, aa), p_mod);
    let x1y0z0 = gradDot(hash32(seed, ba), p_mod - vec3(1.0, 0.0, 0.0));
    let x0y1z0 = gradDot(hash32(seed, ab), p_mod - vec3(0.0, 1.0, 0.0));
    let x1y1z0 = gradDot(hash32(seed, bb), p_mod - vec3(1.0, 1.0, 0.0));
    let x0y0z1 = gradDot(hash32(seed, aa + 1), p_mod - vec3(0.0, 0.0, 1.0));
    let x1y0z1 = gradDot(hash32(seed, ba + 1), p_mod - vec3(1.0, 0.0, 1.0));
    let x0y1z1 = gradDot(hash32(seed, ab + 1), p_mod - vec3(0.0, 1.0, 1.0));
    let x1y1z1 = gradDot(hash32(seed, bb + 1), p_mod - vec3(1.0, 1.0, 1.0));

    let lerp_x0 = mix(x0y0z0, x1y0z0, p_smooth.x);
    let lerp_x1 = mix(x0y1z0, x1y1z0, p_smooth.x);
    let lerp_y0 = mix(lerp_x0, lerp_x1, p_smooth.y);

    let lerp_x2 = mix(x0y0z1, x1y0z1, p_smooth.x);
    let lerp_x3 = mix(x0y1z1, x1y1z1, p_smooth.x);
    let lerp_y1 = mix(lerp_x2, lerp_x3, p_smooth.y);

    let lerp_z = mix(lerp_y0, lerp_y1, p_smooth.z);

    return clamp(lerp_z, - inverseSqrt(2.0), inverseSqrt(2.0)) / inverseSqrt(2.0);
}

// MurmurHash3
fn hash32(seed: u32, x: u32) -> u32 {
    var h: u32 = seed + x;
    h ^= h >> 16;
    h *= 0x85ebca6b;
    h ^= h >> 13;
    h *= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

fn smootherstep(t: f32) -> f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn gradDot(hash: u32, p: vec3f) -> f32 {
    let h = hash & 0xf;
    let u = select(p.y, p.x, h < 8);
    let v = select(select(p.z, p.x, h == 12 || h == 14), p.y, h < 4);
    return select(-u, u, (h & 1) == 0) + select(-v, v, (h & 2) == 0);
}
