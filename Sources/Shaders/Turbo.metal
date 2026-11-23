#include <metal_stdlib>
using namespace metal;

// Colour conversion shared by the input and output passes. Using the same
// coefficients in both directions keeps a real frame and its generated
// neighbour on exactly the same colour path, so there is no flicker.
struct ColorParams {
    float kr;
    float kb;
    uint fullRange;
};

static float3 yuvToRGB(float y, float2 c, constant ColorParams &p) {
    float yn, cb, cr;
    if (p.fullRange) {
        yn = y;
        cb = c.x - 128.0f / 255.0f;
        cr = c.y - 128.0f / 255.0f;
    } else {
        yn = (y * 255.0f - 16.0f) / 219.0f;
        cb = (c.x * 255.0f - 128.0f) / 224.0f;
        cr = (c.y * 255.0f - 128.0f) / 224.0f;
    }
    float kg = 1.0f - p.kr - p.kb;
    float r = yn + 2.0f * (1.0f - p.kr) * cr;
    float b = yn + 2.0f * (1.0f - p.kb) * cb;
    float g = (yn - p.kr * r - p.kb * b) / kg;
    return saturate(float3(r, g, b));
}

static float lumaOf(float3 rgb, constant ColorParams &p) {
    float kg = 1.0f - p.kr - p.kb;
    float yn = p.kr * rgb.r + kg * rgb.g + p.kb * rgb.b;
    return p.fullRange ? yn : (yn * 219.0f + 16.0f) / 255.0f;
}

static float2 chromaOf(float3 rgb, constant ColorParams &p) {
    float kg = 1.0f - p.kr - p.kb;
    float yn = p.kr * rgb.r + kg * rgb.g + p.kb * rgb.b;
    float cb = (rgb.b - yn) / (2.0f * (1.0f - p.kb));
    float cr = (rgb.r - yn) / (2.0f * (1.0f - p.kr));
    return p.fullRange ? float2(cb, cr) + 128.0f / 255.0f
                       : (float2(cb, cr) * 224.0f + 128.0f) / 255.0f;
}

kernel void nv12ToBGRA(texture2d<float, access::read> lumaTex [[texture(0)]],
                       texture2d<float, access::sample> chromaTex [[texture(1)]],
                       texture2d<float, access::write> output [[texture(2)]],
                       constant ColorParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(output.get_width(), output.get_height());
    float3 rgb = yuvToRGB(lumaTex.read(gid).r, chromaTex.sample(s, uv).rg, p);
    output.write(float4(rgb, 1.0f), gid);
}

// HUD detection. A pixel counts as HUD/static when it has not changed for
// several consecutive source frames. Moving scenery almost never matches
// three frames in a row, while quest text, subtitles, the minimap frame and
// menus do. Works anywhere on screen, no hard-coded regions.
struct HudParams {
    uint width;
    uint height;
    float threshold;
    uint reset;
};

constant uint kStableFrames = 4;

static float lumaAt(texture2d<float, access::read> t, int2 p, int2 hi) {
    return dot(t.read(uint2(clamp(p, int2(0), hi))).rgb, float3(0.2126f, 0.7152f, 0.0722f));
}

// A bright 1-2 px stroke with darker pixels on both sides across it (a crosshair bar,
// a dot, a thin ring), horizontal or vertical.
static bool thinStroke(texture2d<float, access::read> t, int2 p, int2 hi) {
    float l = lumaAt(t, p, hi);
    if (l < 0.5f) return false;
    float across = min(l - lumaAt(t, p + int2(0, 2), hi), l - lumaAt(t, p - int2(0, 2), hi));
    float along = min(l - lumaAt(t, p + int2(2, 0), hi), l - lumaAt(t, p - int2(2, 0), hi));
    return max(across, along) > 0.25f;
}

// reticle (extrapolation): GTA-style crosshairs sway by a pixel or two between frames, so
// the "unchanged for N frames" test never catches them. Near the screen centre a thin
// bright stroke that was also there (within 2 px) in the previous frame counts as overlay,
// but only where RIFE says the scene under it moves (>= 3 px): that is exactly where the
// prediction would drag it. A driver, a passenger or a sign that rides along with the
// camera is not moved by the prediction and is left alone.
kernel void hudUpdate(texture2d<float, access::read> previous [[texture(0)]],
                      texture2d<float, access::read> current [[texture(1)]],
                      texture2d<half, access::sample> flow0 [[texture(2)]],
                      texture2d<half, access::sample> flow1 [[texture(3)]],
                      device uchar *still [[buffer(0)]],
                      constant HudParams &h [[buffer(1)]],
                      constant uint &reticle [[buffer(2)]],
                      device const half *net [[buffer(3)]],      // HudNet probabilities, 960x544
                      constant uint &useNet [[buffer(4)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= h.width || gid.y >= h.height) return;
    float3 c = current.read(gid).rgb;
    float3 d = abs(previous.read(gid).rgb - c);
    bool same = max(d.r, max(d.g, d.b)) < h.threshold;
    // Only crisp overlay detail qualifies: a static pixel that stands out from
    // its neighbours (glyph strokes, icon outlines, minimap frame). Flat or dark
    // low-contrast scenery that merely looks still is left to RIFE.
    float l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    int2 p = int2(gid);
    int2 hi = int2(h.width - 1, h.height - 1);
    float contrast = 0.0f;
    const int2 offsets[4] = {int2(-3, 0), int2(3, 0), int2(0, -3), int2(0, 3)};
    for (uint i = 0; i < 4; ++i) {
        float3 n = current.read(uint2(clamp(p + offsets[i], int2(0), hi))).rgb;
        contrast = max(contrast, abs(l - dot(n, float3(0.2126f, 0.7152f, 0.0722f))));
    }
    bool overlay = same && contrast > 0.16f && max(l, max(c.r, max(c.g, c.b))) > 0.35f;
    uint index = gid.y * h.width + gid.x;
    uint count = h.reset ? 0u : uint(still[index]);
    count = overlay ? min(count + 1u, 250u) : 0u;
    if (reticle && count < kStableFrames) {
        int2 centre = int2(h.width, h.height) / 2;
        int2 zone = int2(int(h.height) * 6 / 100, int(h.height) * 4 / 100);  // 64 x 43 px at 1080p
        int2 off = abs(p - centre);
        constexpr sampler fs(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 at = float2(gid) + 0.5f;
        float2 v = float2(flow1.sample(fs, at).rg) - float2(flow0.sample(fs, at).rg);
        if (off.x <= zone.x && off.y <= zone.y && length(v) >= 3.0f && thinStroke(current, p, hi)) {
            bool before = false;
            for (int dy = -2; dy <= 2 && !before; ++dy)
                for (int dx = -2; dx <= 2 && !before; ++dx) before = thinStroke(previous, p + int2(dx, dy), hi);
            if (before) count = kStableFrames;
        }
    }
    // The network adds what it recognises as HUD (crosshairs, counters, prompts, map),
    // on top of the rules above; it never removes their findings.
    if (useNet && count < kStableFrames) {
        uint2 n = min(uint2(gid.x * 960 / h.width, gid.y * 540 / h.height), uint2(959, 539));
        if (float(net[n.y * 960 + n.x]) > 0.5f) count = kStableFrames;
    }
    still[index] = uchar(count);
}

// HudNet input: the frame scaled to 960x540, 4 black rows below (the network's 960x544),
// as planar float16 RGB 0..1, which the Neural Engine takes without any CPU conversion.
kernel void netInput(texture2d<float, access::sample> frame [[texture(0)]],
                     device half *out [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 960 || gid.y >= 544) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 rgb = float3(0.0f);
    if (gid.y < 540) rgb = frame.sample(s, (float2(gid) + 0.5f) / float2(960.0f, 540.0f)).rgb;
    uint plane = 960 * 544, i = gid.y * 960 + gid.x;
    out[i] = half(rgb.r);
    out[plane + i] = half(rgb.g);
    out[2 * plane + i] = half(rgb.b);
}

static float hudWeight(device const uchar *still, int2 p, constant HudParams &h) {
    int w = int(h.width), ht = int(h.height);
    float weight = 0.0f;
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            int2 q = clamp(p + int2(dx, dy), int2(0), int2(w - 1, ht - 1));
            if (uint(still[q.y * w + q.x]) >= kStableFrames) {
                int d = max(abs(dx), abs(dy));
                weight = max(weight, d <= 1 ? 1.0f : 0.65f);
            }
        }
    }
    return weight;
}

// Writes the generated frame as NV12. One thread per 2x2 block. Where the HUD
// is stable the original NV12 samples of the current frame are passed through
// untouched, so text and icons stay pixel-exact instead of being dragged along
// with the moving background.
kernel void composeNV12(texture2d<float, access::read> generated [[texture(0)]],
                        texture2d<float, access::read> curLuma [[texture(1)]],
                        texture2d<float, access::read> curChroma [[texture(2)]],
                        texture2d<float, access::write> outLuma [[texture(3)]],
                        texture2d<float, access::write> outChroma [[texture(4)]],
                        device const uchar *still [[buffer(0)]],
                        constant HudParams &h [[buffer(1)]],
                        constant ColorParams &p [[buffer(2)]],
                        constant uint &protect [[buffer(3)]],
                        uint2 block [[thread_position_in_grid]]) {
    if (block.x >= outChroma.get_width() || block.y >= outChroma.get_height()) return;
    float3 sum = 0.0f;
    float weightSum = 0.0f;
    for (uint i = 0; i < 4; ++i) {
        uint2 px = block * 2 + uint2(i & 1, i >> 1);
        px = min(px, uint2(h.width - 1, h.height - 1));
        float3 rgb = generated.read(px).rgb;
        sum += rgb;
        float w = protect ? hudWeight(still, int2(px), h) : 0.0f;
        weightSum += w;
        float y = mix(lumaOf(rgb, p), curLuma.read(px).r, w);
        outLuma.write(float4(y), px);
    }
    float2 c = chromaOf(sum * 0.25f, p);
    c = mix(c, curChroma.read(block).rg, weightSum * 0.25f);
    outChroma.write(float4(c, 0.0f, 0.0f), block);
}

// ---------------------------------------------------------------------------
// Extrapolation. RIFE gives, at the midpoint between frames N-1 and N, flows to
// both frames (pixels, padded canvas anchored top-left). Their difference is the
// motion of the content over one source frame. The predicted frame half a source
// frame after N samples N backwards along that motion, so the real frame can be
// shown immediately instead of waiting for N+1.
struct ExtrapParams {
    float step;      // fraction of one source frame to predict (0.5 = midpoint)
    float maxShift;  // pixels; larger predictions are treated as unreliable
};

// Character edges at fast camera moves ("halo" modes, chosen in the FG settings; 0 = off).
// Where the predicted shift changes sharply within a few dozen pixels (a still character
// against a backdrop the camera sweeps past), RIFE's quarter-resolution flow blends the two
// motions: the prediction bends the character's outline and drags it over the backdrop.
// What comes out from behind the character is unknown to any prediction, so these modes
// make that band less visible instead of guessing it:
//   bit 0  soft: blur the band along the backdrop's motion, like the game's own motion blur
//   bit 1  calm: fade the band towards the real frame (less flicker between real and predicted)
//   bit 2  hero: the slower side (the character the camera follows) keeps its place exactly
//   bit 3  still: like calm, but the band shows the real frame fully (no prediction there:
//          the edge looks as it does without frame generation)
//   bit 4  split: calm/still only on the character's side of the edge, soft only on the
//          backdrop's side (the character stays exactly as in the real frame, the backdrop
//          next to it moves on, blurred)
// Ordinary motion never reaches `lo`, so with any mode the rest of the picture is unchanged.
struct HaloParams {
    uint mode;
    float lo, hi;     // predicted shift difference (px) where the handling starts / is full
    float blur;       // blur length as a fraction of that difference
    float2 camera;    // median motion of the frame (px per source frame)
};

static float2 midMotion(texture2d<half, access::sample> flow0, texture2d<half, access::sample> flow1, float2 p) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    return float2(flow1.sample(s, p).rg) - float2(flow0.sample(s, p).rg);
}

static bool hudNear(device const uchar *still, float2 q, constant HudParams &h) {
    int2 c = int2(floor(q));
    int2 hi = int2(h.width - 1, h.height - 1);
    // Radius 2: also the dark outline / drop shadow that overlay strokes carry.
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            int2 p = clamp(c + int2(dx, dy), int2(0), hi);
            if (uint(still[p.y * int(h.width) + p.x]) >= kStableFrames) return true;
        }
    }
    return false;
}

// One pixel of the HUD mask (cheap check for the halo blur taps).
static bool hudAt(device const uchar *still, float2 q, constant HudParams &h) {
    int2 p = clamp(int2(floor(q)), int2(0), int2(h.width - 1, h.height - 1));
    return uint(still[p.y * int(h.width) + p.x]) >= kStableFrames;
}

// People mask (an earlier frame, Vision; `age` frames ago) moved onto the current frame along
// RIFE's motion.
static float personAt(texture2d<float, access::sample> person, texture2d<half, access::sample> flow0,
                      texture2d<half, access::sample> flow1, float2 p, float2 size, float age) {
    constexpr sampler ms(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 v = midMotion(flow0, flow1, p);
    return person.sample(ms, (p - age * v) / size).r;
}

// Vision input: the frame scaled to the input size.
kernel void personInput(texture2d<float, access::sample> frame [[texture(0)]],
                        texture2d<float, access::write> out [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    out.write(float4(frame.sample(s, (float2(gid) + 0.5f) / float2(out.get_width(), out.get_height())).rgb, 1.0f), gid);
}

// Field for the halo modes at an eighth of the resolution (one texel per 8x8 pixels; RIFE's
// flow is smooth at that scale): the slowest and the fastest motion within ±32 px (xy, zw) and
// how strongly the predicted shift changes there (edge strength). Once per frame instead of
// per pixel.
kernel void haloField(texture2d<half, access::sample> flow0 [[texture(0)]],
                      texture2d<half, access::sample> flow1 [[texture(1)]],
                      texture2d<float, access::write> field [[texture(2)]],
                      texture2d<float, access::write> strength [[texture(3)]],
                      constant HaloParams &halo [[buffer(0)]],
                      constant float &step [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= field.get_width() || gid.y >= field.get_height()) return;
    const float2 dirs[8] = {float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1),
                            float2(0.7071f, 0.7071f), float2(-0.7071f, 0.7071f),
                            float2(0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)};
    const float radii[3] = {8.0f, 18.0f, 32.0f};
    const float weight[3] = {1.0f, 0.85f, 0.55f};   // fades out away from the edge
    float2 y = float2(gid) * 8.0f + 4.0f;
    float2 here = midMotion(flow0, flow1, y);
    float2 vs = here, vf = here;
    float ls = length(here), lf = ls, s = 0.0f;
    for (int r = 0; r < 3; ++r) {
        float2 rs = here, rf = here;
        float rls = length(here), rlf = rls;
        for (int d = 0; d < 8; ++d) {
            float2 v = midMotion(flow0, flow1, y + dirs[d] * radii[r]);
            float l = length(v);
            if (l < rls) { rls = l; rs = v; }
            if (l > rlf) { rlf = l; rf = v; }
        }
        s = max(s, weight[r] * smoothstep(halo.lo, halo.hi, step * length(rf - rs)));
        if (rls < ls) { ls = rls; vs = rs; }
        if (rlf > lf) { lf = rlf; vf = rf; }
    }
    field.write(float4(vs, vf), gid);
    strength.write(float4(s), gid);
}

kernel void extrapolateFrame(texture2d<float, access::sample> current [[texture(0)]],
                             texture2d<half, access::sample> flow0 [[texture(1)]],
                             texture2d<half, access::sample> flow1 [[texture(2)]],
                             texture2d<float, access::write> output [[texture(3)]],
                             constant ExtrapParams &e [[buffer(0)]],
                             device const uchar *still [[buffer(1)]],
                             constant HudParams &h [[buffer(2)]],
                             constant uint &avoidHud [[buffer(3)]],
                             device const float *trust [[buffer(4)]],   // per motion block, 0..1
                             constant uint4 &grid [[buffer(5)]],        // frameW, frameH, blocksX, blocksY (0 = all trusted)
                             texture2d<float, access::sample> person [[texture(4)]],
                             constant uint &usePerson [[buffer(6)]],
                             constant HaloParams &halo [[buffer(7)]],
                             texture2d<float, access::sample> haloMotion [[texture(5)]],   // haloField
                             texture2d<float, access::sample> haloEdge [[texture(6)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 y = float2(gid) + 0.5f;
    float stepTrust = e.step;
    // Content now at y was at y - w in frame N, where w = step * velocity of that content.
    // The motion field lives at midpoint coordinates: content at p in frame N sat at
    // p - v/2 at the midpoint. Two fixed-point iterations resolve both offsets.
    float2 w = e.step * midMotion(flow0, flow1, y);
    for (int i = 0; i < 3; ++i) {
        float2 p = y - w;
        float2 vm = midMotion(flow0, flow1, p);
        w = e.step * midMotion(flow0, flow1, p - 0.5f * vm);
    }
    if (grid.z > 0) {
        // Bilinear between block centres so untrusted areas fade in without a seam.
        float2 b = (y / (float2(grid.xy) / float2(grid.zw))) - 0.5f;
        int2 b0 = int2(floor(b));
        float2 f = b - float2(b0);
        int2 hiB = int2(grid.zw) - 1;
        int2 a00 = clamp(b0, int2(0), hiB), a11 = clamp(b0 + 1, int2(0), hiB);
        float t00 = trust[a00.y * grid.z + a00.x], t10 = trust[a00.y * grid.z + a11.x];
        float t01 = trust[a11.y * grid.z + a00.x], t11 = trust[a11.y * grid.z + a11.x];
        float tr = mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
        w *= tr;
        stepTrust *= tr;
    }
    // At the edge of a person: RIFE's quarter-resolution flow blends the person's motion
    // with the backdrop's there (a halo around a head while the camera circles the player).
    // With the people mask the two are kept apart: the person is in front, inside it the
    // person's own motion applies, outside the backdrop's, and backdrop that comes out from
    // behind the person is stretched from beside it instead of smearing the person over it.
    if (usePerson && stepTrust > 0.0f) {
        float2 size = float2(output.get_width(), output.get_height());
        float age = float((usePerson & 255u) - 1u);
        bool frontOnly = (usePerson & 256u) != 0u;   // keep the person, leave the backdrop to RIFE
        bool soft = (usePerson & 512u) != 0u;        // front only, blended by mask confidence
        const float2 dirs[8] = {float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1),
                                float2(0.7071f, 0.7071f), float2(-0.7071f, 0.7071f),
                                float2(0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)};
        const float radii[4] = {8.0f, 16.0f, 28.0f, 44.0f};
        bool haveP = false, haveB = false;
        float2 vp = float2(0.0f), vb = float2(0.0f);
        for (int r = 0; r < 4 && (soft || !(haveP && haveB)); ++r) {
            for (int d = 0; d < 8; ++d) {
                float2 p = y + dirs[d] * radii[r];
                float pm = personAt(person, flow0, flow1, p, size, age);
                // Soft: the deepest samples, away from the edge where RIFE's flow is blended.
                if ((soft || !haveP) && pm > 0.85f) { vp = midMotion(flow0, flow1, p); haveP = true; }
                if ((soft || !haveB) && pm < 0.15f) { vb = midMotion(flow0, flow1, p); haveB = true; }
            }
        }
        if (haveP && haveB && length(vp - vb) > 3.0f) {
            // From here on the mask is moved by the person's own motion (taken from inside
            // the person), not by RIFE's motion at the edge, which is the blurred one.
            constexpr sampler ms(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 wp = stepTrust * vp, wb = stepTrust * vb;
            #define PERSON(q) person.sample(ms, ((q) - age * vp) / size).r
            if (soft) {
                w = mix(w, wp, smoothstep(0.6f, 0.95f, PERSON(y - wp)));
            } else if (PERSON(y - wp) > 0.35f) {
                w = wp;                                   // the person reaches here: in front
            } else if (frontOnly) {
                // backdrop: RIFE's own motion, unchanged
            } else if (PERSON(y - wb) < 0.35f) {
                w = wb;                                   // backdrop that was in view
            } else {
                w = float2(0.0f);                         // backdrop from behind the person:
                for (int k = 3; k >= 1; --k) {            // stretch the nearest visible backdrop
                    float2 wk = wb * (float(k) / 4.0f);
                    if (PERSON(y - wk) < 0.35f) { w = wk; break; }
                }
            }
            #undef PERSON
        }
    }
    // Character edges at fast camera moves (see HaloParams).
    float haloS = 0.0f, haloLen = 0.0f, haloT = 0.0f;
    float2 haloDir = float2(0.0f);
    if (halo.mode != 0u && stepTrust > 0.0f) {
        constexpr sampler fs(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = y / float2(output.get_width(), output.get_height());
        // The field is computed for the frame's step; untrusted blocks scale it down with it.
        haloS = haloEdge.sample(fs, uv).r * min(stepTrust / max(e.step, 1e-4f), 1.0f);
        if (haloS < 0.004f) haloS = 0.0f;
        if (haloS > 0.0f) {
            float4 f = haloMotion.sample(fs, uv);
            float2 vs = f.xy, vf = f.zw;
            float ls = length(vs), lf = length(vf);
            float2 here = midMotion(flow0, flow1, y);
            float2 rel = vf - vs;
            haloLen = stepTrust * length(rel);
            haloDir = rel / max(length(rel), 1e-3f);
            // Where this pixel's own motion sits between the slow and the fast side (0..1).
            haloT = clamp(dot(here - vs, rel) / max(dot(rel, rel), 1e-3f), 0.0f, 1.0f);
            if ((halo.mode & 4u) != 0u) {
                // The slower side is the character the camera follows: it holds (nearly) still
                // on screen while the camera sweeps the backdrop past it. Only in that case: a
                // car crossing a still street must not be held back.
                float cam = max(length(halo.camera), 1.0f);
                float follows = 1.0f - smoothstep(0.3f, 0.5f, length(vf - halo.camera) / cam);
                float held = 1.0f - smoothstep(0.25f, 0.45f, ls / max(lf, 1.0f));
                w = mix(w, stepTrust * vs, haloS * follows * held);
            }
        }
    }
    float len = length(w);
    if (len > e.maxShift) w *= e.maxShift / len;
    // Never drag overlay pixels along with the scene: that leaves a ghost copy of the
    // crosshair or text beside the real one (which compose restores in place). Thin
    // overlay is stepped over by sampling the scene just beside it; when that fails
    // (a big panel) the pixel keeps the real frame. Only for pixels away from the mask:
    // the mask also catches things that merely stand still on screen (a third-person
    // character's cap against the sky), and re-sampling their own edges chews them up.
    float2 q = y - w;
    if (avoidHud && len > 0.5f && !hudNear(still, y, h) && hudNear(still, q, h)) {
        const float2 steps[12] = {float2(0, 3), float2(0, -3), float2(3, 0), float2(-3, 0),
                                  float2(0, 5), float2(0, -5), float2(5, 0), float2(-5, 0),
                                  float2(0, 7), float2(0, -7), float2(7, 0), float2(-7, 0)};
        float2 found = y;
        for (int i = 0; i < 12; ++i) {
            if (!hudNear(still, q + steps[i], h)) { found = q + steps[i]; break; }
        }
        q = found;
    }
    float3 color = current.sample(s, q).rgb;
    if (haloS > 0.0f) {
        if ((halo.mode & 1u) != 0u) {
            // Blur along the backdrop's motion, strongest on the backdrop's side of the edge
            // (the character's own pixels stay sharp). HUD pixels are left out of the blur.
            bool split = (halo.mode & 16u) != 0u;
            float k = haloS * (split ? smoothstep(0.3f, 0.8f, haloT) : smoothstep(0.1f, 0.6f, haloT));
            float blurLen = halo.blur * haloLen * k;
            if (blurLen > 1.0f) {
                float3 sum = color;
                float total = 1.0f;
                for (int i = -4; i <= 4; ++i) {
                    if (i == 0) continue;
                    float t = float(i) / 4.0f;
                    float2 tap = q + haloDir * (0.5f * blurLen * t);
                    if (avoidHud && hudAt(still, tap, h)) continue;
                    float wt = 1.0f - 0.5f * abs(t);
                    sum += wt * current.sample(s, tap).rgb;
                    total += wt;
                }
                color = sum / total;
            }
        }
        if ((halo.mode & 10u) != 0u) {
            float calm = (halo.mode & 8u) != 0u ? 1.0f : 0.6f;
            if ((halo.mode & 16u) != 0u) calm *= 1.0f - smoothstep(0.35f, 0.8f, haloT);
            color = mix(color, current.sample(s, y).rgb, calm * haloS);
        }
    }
    output.write(float4(color, 1.0f), gid);
}

// ---------------------------------------------------------------------------
// Edge-aware (layered) extrapolation.
// RIFE's flow is estimated at a quarter of the resolution, so where a still character meets
// a fast backdrop (or a car crosses a still street) the motion is smeared across a band of
// 15-30 px and the prediction drags the edge of the object with it. Two passes fix that:
//  1. refineMotion (half resolution): for each point pick, among the motions found in its
//     neighbourhood, the one that actually explains how the picture got there from the
//     previous frame. Edges become sharp: every point belongs to one layer.
//  2. extrapolateLayered: where two layers compete for an output pixel, the one moving
//     differently from the camera is in front (characters, cars; the backdrop follows the
//     camera). Where the backdrop re-appears from behind an object it is stretched up to
//     the object instead of smearing the object over it.

kernel void refineMotion(texture2d<float, access::sample> previous [[texture(0)]],
                         texture2d<float, access::sample> current [[texture(1)]],
                         texture2d<half, access::sample> flow0 [[texture(2)]],
                         texture2d<half, access::sample> flow1 [[texture(3)]],
                         texture2d<half, access::write> refined [[texture(4)]],
                         constant float2 &camera [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= refined.get_width() || gid.y >= refined.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    const float3 kL = float3(0.2126f, 0.7152f, 0.0722f);
    float2 x = float2(gid) * 2.0f + 1.0f;   // centre of this 2x2 block, full-res pixels
    float2 here = midMotion(flow0, flow1, x);
    // An edge between layers shows in RIFE's own field as two clearly different motions
    // 40 px apart. Elsewhere (most of the frame, and anything blurred by fast motion where
    // matching is unreliable) RIFE's motion stands as it is.
    const float2 ring[8] = {float2(40, 0), float2(-40, 0), float2(0, 40), float2(0, -40),
                            float2(28, 28), float2(-28, 28), float2(28, -28), float2(-28, -28)};
    float2 lo = here, hi2 = here;
    float loDev = length(here - camera), hiDev = loDev;
    for (int i = 0; i < 8; ++i) {
        float2 m = midMotion(flow0, flow1, x + ring[i]);
        float dev = length(m - camera);
        if (dev < loDev) { loDev = dev; lo = m; }
        if (dev > hiDev) { hiDev = dev; hi2 = m; }
    }
    if (length(hi2 - lo) < max(8.0f, 0.3f * max(length(hi2), length(lo)))) {
        refined.write(half4(half2(here), 0.0h, 1.0h), gid);   // a = 1: no edge here
        return;
    }
    float best = 1e9f;
    float2 bestMotion = here;
    // Candidates: RIFE's motion here, the two layers found around, the camera (backdrop)
    // and standing still (characters the camera follows).
    for (int k = 0; k < 5; ++k) {
        float2 c = k == 0 ? here : k == 1 ? lo : k == 2 ? hi2 : k == 3 ? camera : float2(0.0f);
        // Two scales: the point and its immediate neighbours decide which layer it is on
        // (sharp edges); a wider sparse patch guards against chance matches.
        float nearErr = 0.0f, wideErr = 0.0f;
        for (int oy = -1; oy <= 1; ++oy) {
            for (int ox = -1; ox <= 1; ++ox) {
                float2 o = float2(ox, oy);
                nearErr += abs(dot(current.sample(s, x + o).rgb, kL) - dot(previous.sample(s, x + o - c).rgb, kL));
            }
        }
        for (int oy = -2; oy <= 2; ++oy) {
            for (int ox = -2; ox <= 2; ++ox) {
                float2 o = float2(ox, oy) * 3.0f;
                wideErr += abs(dot(current.sample(s, x + o).rgb, kL) - dot(previous.sample(s, x + o - c).rgb, kL));
            }
        }
        float err = nearErr / 9.0f + 0.25f * wideErr / 25.0f;
        if (k == 0) err *= 0.85f;          // RIFE's own estimate unless another clearly fits better
        else if (k == 3) err *= 0.92f;     // then the backdrop
        if (err < best) { best = err; bestMotion = c; }
    }
    // Nothing matches: the point has just come into view from behind something, which in
    // practice is the backdrop, moving with the camera.
    if (best > 0.075f) bestMotion = camera;
    refined.write(half4(half2(bestMotion), half(min(best, 1.0f)), 0.0h), gid);   // a = 0: edge zone
}

// A point that only just came into view (hidden behind another layer in the previous
// frame) cannot be matched, so chance matches label it with any motion. If it matched
// poorly and the backdrop would have brought it from where another layer stands now, it is
// freshly uncovered backdrop.
static float2 settledMotion(texture2d<half, access::read> raw, int2 p, int2 hi, float2 camera) {
    half4 t = raw.read(uint2(clamp(p, int2(0), hi)));
    float2 v = float2(t.rg);
    if (t.a > 0.5h || float(t.b) <= 0.02f) return v;   // no edge here, or a confident match
    float2 from = (float2(clamp(p, int2(0), hi)) * 2.0f + 1.0f - camera - 1.0f) * 0.5f;
    float2 there = float2(raw.read(uint2(clamp(int2(round(from)), int2(0), hi))).rg);
    return length(there - camera) > max(4.0f, 0.25f * length(camera)) ? camera : v;
}

// Vector median over 3x3: a lone point labelled with the wrong layer (a chance match in a
// freshly uncovered area) takes its neighbours' motion; edges between layers stay sharp.
kernel void cleanMotion(texture2d<half, access::read> raw [[texture(0)]],
                        texture2d<half, access::write> clean [[texture(1)]],
                        constant float2 &camera [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= clean.get_width() || gid.y >= clean.get_height()) return;
    int2 hi = int2(raw.get_width() - 1, raw.get_height() - 1);
    float2 v[9];
    int n = 0;
    for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx)
            v[n++] = settledMotion(raw, int2(gid) + int2(dx, dy), hi, camera);
    float best = 1e9f;
    float2 pick = v[4];
    for (int i = 0; i < 9; ++i) {
        float sum = 0.0f;
        for (int j = 0; j < 9; ++j) sum += length(v[i] - v[j]);
        if (sum < best) { best = sum; pick = v[i]; }
    }
    half4 centre = raw.read(gid);
    if (centre.a > 0.5h) { clean.write(centre, gid); return; }   // no edge: leave RIFE's motion
    clean.write(half4(half2(pick), centre.b, 0.0h), gid);
}

struct LayerParams {
    float step;
    float maxShift;
    float2 camera;
    uint debug;   // 1: layer map (|motion|/64), 2: branch taken (diagnostics only)
};

static float2 layerMotion(texture2d<half, access::sample> refined, float2 p) {
    constexpr sampler n(coord::pixel, address::clamp_to_edge, filter::nearest);
    return float2(refined.sample(n, p * 0.5f).rg);
}

// Content with motion c that lands on y sits at y - step*c now; it belongs there if the
// point it comes from really moves with c.
static bool landsHere(texture2d<half, access::sample> refined, float2 y, float2 c, float step) {
    float2 v = layerMotion(refined, y - step * c);
    return length(v - c) <= max(1.0f, 0.1f * length(c));
}

static float blockTrustAt(device const float *trust, constant uint4 &grid, float2 y) {
    if (grid.z == 0) return 1.0f;
    float2 b = (y / (float2(grid.xy) / float2(grid.zw))) - 0.5f;
    int2 b0 = int2(floor(b));
    float2 f = b - float2(b0);
    int2 hiB = int2(grid.zw) - 1;
    int2 a00 = clamp(b0, int2(0), hiB), a11 = clamp(b0 + 1, int2(0), hiB);
    float t00 = trust[a00.y * grid.z + a00.x], t10 = trust[a00.y * grid.z + a11.x];
    float t01 = trust[a11.y * grid.z + a00.x], t11 = trust[a11.y * grid.z + a11.x];
    return mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
}

kernel void extrapolateLayered(texture2d<float, access::sample> current [[texture(0)]],
                               texture2d<half, access::sample> refined [[texture(1)]],
                               texture2d<float, access::write> output [[texture(2)]],
                               constant LayerParams &e [[buffer(0)]],
                               device const uchar *still [[buffer(1)]],
                               constant HudParams &h [[buffer(2)]],
                               constant uint &avoidHud [[buffer(3)]],
                               device const float *trust [[buffer(4)]],
                               constant uint4 &grid [[buffer(5)]],
                               texture2d<half, access::sample> flow0 [[texture(3)]],
                               texture2d<half, access::sample> flow1 [[texture(4)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 y = float2(gid) + 0.5f;
    float step = e.step * blockTrustAt(trust, grid, y);

    // Away from layer edges: exactly the plain warp (RIFE's smooth sub-pixel motion).
    float2 wPlain = step * midMotion(flow0, flow1, y);
    for (int i = 0; i < 3; ++i) {
        float2 p = y - wPlain;
        float2 vm = midMotion(flow0, flow1, p);
        wPlain = step * midMotion(flow0, flow1, p - 0.5f * vm);
    }

    // The layer arriving here by its own motion (fixed point of q = y - step * v(q)).
    float2 c = layerMotion(refined, y);
    for (int i = 0; i < 3; ++i) c = layerMotion(refined, y - step * c);
    bool found = landsHere(refined, y, c, step);
    float2 chosen = c;
    float front = found ? length(c - e.camera) : -1.0f;
    float2 back = c;
    float backDev = length(c - e.camera);
    float2 ahead = c;              // the layer moving most unlike the camera (likely in front)
    float aheadDev = backDev;

    // Other layers nearby: a band up to ~40 px wide can change hands at an edge.
    const float2 dirs[4] = {float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1)};
    const float radii[3] = {10.0f, 24.0f, 40.0f};
    float separate = max(4.0f, 0.25f * length(c));
    bool edge = false;
    for (int r = 0; r < 3; ++r) {
        for (int d = 0; d < 4; ++d) {
            float2 cn = layerMotion(refined, y + dirs[d] * radii[r]);
            if (length(cn - c) < separate) continue;
            edge = true;   // refined only disagrees inside edge zones
            float dev = length(cn - e.camera);
            if (dev < backDev) { backDev = dev; back = cn; }
            if (dev > aheadDev) { aheadDev = dev; ahead = cn; }
            if (dev > front && landsHere(refined, y, cn, step)) { chosen = cn; front = dev; found = true; }
        }
    }

    float2 w = float2(0.0f);
    float branch = 0.0f;
    constexpr sampler zn(coord::pixel, address::clamp_to_edge, filter::nearest);
    bool zone = refined.sample(zn, y * 0.5f).a < 0.5h;
    if (!edge || !zone) {
        w = wPlain;
    } else if (found) {
        w = step * chosen;
        branch = length(chosen - c) < 0.5f ? 0.25f : 0.5f;
    } else {
        // Uncovered backdrop: the part hidden behind the object is unknown, so stretch the
        // backdrop from as far along its motion as still belongs to it. A still backdrop
        // behind a moving object has no motion to follow: then look behind the object,
        // against its motion, for the nearest backdrop instead of smearing the object.
        float tol = max(1.0f, 0.1f * length(back));
        bool filled = false;
        for (int k = 4; k >= 1 && !filled; --k) {
            float2 wk = step * back * (float(k) / 4.0f);
            if (length(layerMotion(refined, y - wk) - back) <= tol) { w = wk; filled = true; branch = 0.75f; }
        }
        for (int k = 1; k <= 4 && !filled; ++k) {
            float2 wk = step * ahead * (float(k) / 4.0f);
            if (length(layerMotion(refined, y - wk) - back) <= tol) { w = wk; filled = true; branch = 1.0f; }
        }
    }
    float len = length(w);
    if (len > e.maxShift) w *= e.maxShift / len;
    float2 q = y - w;
    if (avoidHud && len > 0.5f && !hudNear(still, y, h) && hudNear(still, q, h)) {
        const float2 steps[12] = {float2(0, 3), float2(0, -3), float2(3, 0), float2(-3, 0),
                                  float2(0, 5), float2(0, -5), float2(5, 0), float2(-5, 0),
                                  float2(0, 7), float2(0, -7), float2(7, 0), float2(-7, 0)};
        float2 alt = y;
        for (int i = 0; i < 12; ++i) {
            if (!hudNear(still, q + steps[i], h)) { alt = q + steps[i]; break; }
        }
        q = alt;
    }
    if (e.debug == 1) { output.write(float4(float3(length(layerMotion(refined, y)) / 64.0f), 1.0f), gid); return; }
    if (e.debug == 2) { output.write(float4(float3(branch), 1.0f), gid); return; }
    if (e.debug == 3) {
        constexpr sampler n(coord::pixel, address::clamp_to_edge, filter::nearest);
        output.write(float4(float3(float(refined.sample(n, y * 0.5f).b) * 10.0f), 1.0f), gid);
        return;
    }
    output.write(float4(current.sample(s, q).rgb, 1.0f), gid);
}

// Coarse motion map for the damping logic: one mean motion vector per block of
// the visible frame, read back on the CPU to estimate camera motion robustly.
// z = how badly the two frames disagree after RIFE's warps (luma, 0..1), w = how
// different they are without any warp. Real motion: the warp explains most of the
// change (z << w). A cut between unrelated shots: the warp explains almost nothing.
kernel void motionBlocks(texture2d<half, access::sample> flow0 [[texture(0)]],
                         texture2d<half, access::sample> flow1 [[texture(1)]],
                         texture2d<float, access::sample> previous [[texture(2)]],
                         texture2d<float, access::sample> current [[texture(3)]],
                         device float4 *blocks [[buffer(0)]],
                         constant uint4 &dims [[buffer(1)]],  // frameW, frameH, blocksX, blocksY
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dims.z || gid.y >= dims.w) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    const float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);
    float2 size = float2(dims.xy) / float2(dims.zw);
    float2 sum = 0.0f;
    float residual = 0.0f, raw = 0.0f;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 p = (float2(gid) + (float2(i, j) + 0.5f) / 4.0f) * size;
            float2 f0 = float2(flow0.sample(s, p).rg), f1 = float2(flow1.sample(s, p).rg);
            sum += f1 - f0;
            float a = dot(previous.sample(s, p + f0).rgb, kLuma);
            float b = dot(current.sample(s, p + f1).rgb, kLuma);
            residual += abs(a - b);
            raw += abs(dot(previous.sample(s, p).rgb, kLuma) - dot(current.sample(s, p).rgb, kLuma));
        }
    }
    blocks[gid.y * dims.z + gid.x] = float4(sum / 16.0f, residual / 16.0f, raw / 16.0f);
}
