#include <metal_stdlib>
using namespace metal;
#define QK_K 256
struct block_iq2_xxs { half d; ushort qs[QK_K/8]; };
static constant uchar ds4_metal_kmask_iq2xs[8] = {
    1, 2, 4, 8, 16, 32, 64, 128
};

static constant uchar ds4_metal_ksigns_iq2xs[128] = {
      0, 129, 130,   3, 132,   5,   6, 135, 136,   9,  10, 139,  12, 141, 142,  15,
    144,  17,  18, 147,  20, 149, 150,  23,  24, 153, 154,  27, 156,  29,  30, 159,
    160,  33,  34, 163,  36, 165, 166,  39,  40, 169, 170,  43, 172,  45,  46, 175,
     48, 177, 178,  51, 180,  53,  54, 183, 184,  57,  58, 187,  60, 189, 190,  63,
    192,  65,  66, 195,  68, 197, 198,  71,  72, 201, 202,  75, 204,  77,  78, 207,
     80, 209, 210,  83, 212,  85,  86, 215, 216,  89,  90, 219,  92, 221, 222,  95,
     96, 225, 226,  99, 228, 101, 102, 231, 232, 105, 106, 235, 108, 237, 238, 111,
    240, 113, 114, 243, 116, 245, 246, 119, 120, 249, 250, 123, 252, 125, 126, 255,
};

static constant ulong ds4_metal_iq2xxs_grid[256] = {
    0x0808080808080808, 0x080808080808082b, 0x0808080808081919, 0x0808080808082b08,
    0x0808080808082b2b, 0x0808080808190819, 0x0808080808191908, 0x08080808082b0808,
    0x08080808082b082b, 0x08080808082b2b08, 0x08080808082b2b2b, 0x0808080819080819,
    0x0808080819081908, 0x0808080819190808, 0x0808080819192b08, 0x08080808192b0819,
    0x08080808192b1908, 0x080808082b080808, 0x080808082b08082b, 0x080808082b082b2b,
    0x080808082b2b082b, 0x0808081908080819, 0x0808081908081908, 0x0808081908190808,
    0x0808081908191919, 0x0808081919080808, 0x080808192b081908, 0x080808192b192b08,
    0x0808082b08080808, 0x0808082b0808082b, 0x0808082b082b082b, 0x0808082b2b08082b,
    0x0808190808080819, 0x0808190808081908, 0x0808190808190808, 0x08081908082b0819,
    0x08081908082b1908, 0x0808190819080808, 0x080819081908082b, 0x0808190819082b08,
    0x08081908192b0808, 0x080819082b080819, 0x080819082b081908, 0x080819082b190808,
    0x080819082b2b1908, 0x0808191908080808, 0x080819190808082b, 0x0808191908082b08,
    0x08081919082b0808, 0x080819191908192b, 0x08081919192b2b19, 0x080819192b080808,
    0x080819192b190819, 0x0808192b08082b19, 0x0808192b08190808, 0x0808192b19080808,
    0x0808192b2b081908, 0x0808192b2b2b1908, 0x08082b0808080808, 0x08082b0808081919,
    0x08082b0808082b08, 0x08082b0808191908, 0x08082b08082b2b08, 0x08082b0819080819,
    0x08082b0819081908, 0x08082b0819190808, 0x08082b081919082b, 0x08082b082b082b08,
    0x08082b1908081908, 0x08082b1919080808, 0x08082b2b0808082b, 0x08082b2b08191908,
    0x0819080808080819, 0x0819080808081908, 0x0819080808190808, 0x08190808082b0819,
    0x0819080819080808, 0x08190808192b0808, 0x081908082b081908, 0x081908082b190808,
    0x081908082b191919, 0x0819081908080808, 0x0819081908082b08, 0x08190819082b0808,
    0x0819081919190808, 0x0819081919192b2b, 0x081908192b080808, 0x0819082b082b1908,
    0x0819082b19081919, 0x0819190808080808, 0x0819190808082b08, 0x08191908082b0808,
    0x08191908082b1919, 0x0819190819082b19, 0x081919082b080808, 0x0819191908192b08,
    0x08191919192b082b, 0x0819192b08080808, 0x0819192b0819192b, 0x08192b0808080819,
    0x08192b0808081908, 0x08192b0808190808, 0x08192b0819080808, 0x08192b082b080819,
    0x08192b1908080808, 0x08192b1908081919, 0x08192b192b2b0808, 0x08192b2b19190819,
    0x082b080808080808, 0x082b08080808082b, 0x082b080808082b2b, 0x082b080819081908,
    0x082b0808192b0819, 0x082b08082b080808, 0x082b08082b08082b, 0x082b0819082b2b19,
    0x082b081919082b08, 0x082b082b08080808, 0x082b082b0808082b, 0x082b190808080819,
    0x082b190808081908, 0x082b190808190808, 0x082b190819080808, 0x082b19081919192b,
    0x082b191908080808, 0x082b191919080819, 0x082b1919192b1908, 0x082b192b2b190808,
    0x082b2b0808082b08, 0x082b2b08082b0808, 0x082b2b082b191908, 0x082b2b2b19081908,
    0x1908080808080819, 0x1908080808081908, 0x1908080808190808, 0x1908080808192b08,
    0x19080808082b0819, 0x19080808082b1908, 0x1908080819080808, 0x1908080819082b08,
    0x190808081919192b, 0x19080808192b0808, 0x190808082b080819, 0x190808082b081908,
    0x190808082b190808, 0x1908081908080808, 0x19080819082b0808, 0x19080819192b0819,
    0x190808192b080808, 0x190808192b081919, 0x1908082b08080819, 0x1908082b08190808,
    0x1908082b19082b08, 0x1908082b1919192b, 0x1908082b192b2b08, 0x1908190808080808,
    0x1908190808082b08, 0x19081908082b0808, 0x190819082b080808, 0x190819082b192b19,
    0x190819190819082b, 0x19081919082b1908, 0x1908192b08080808, 0x19082b0808080819,
    0x19082b0808081908, 0x19082b0808190808, 0x19082b0819080808, 0x19082b0819081919,
    0x19082b1908080808, 0x19082b1919192b08, 0x19082b19192b0819, 0x19082b192b08082b,
    0x19082b2b19081919, 0x19082b2b2b190808, 0x1919080808080808, 0x1919080808082b08,
    0x1919080808190819, 0x1919080808192b19, 0x19190808082b0808, 0x191908082b080808,
    0x191908082b082b08, 0x1919081908081908, 0x191908191908082b, 0x191908192b2b1908,
    0x1919082b2b190819, 0x191919082b190808, 0x191919082b19082b, 0x1919191908082b2b,
    0x1919192b08080819, 0x1919192b19191908, 0x19192b0808080808, 0x19192b0808190819,
    0x19192b0808192b19, 0x19192b08192b1908, 0x19192b1919080808, 0x19192b2b08082b08,
    0x192b080808081908, 0x192b080808190808, 0x192b080819080808, 0x192b0808192b2b08,
    0x192b081908080808, 0x192b081919191919, 0x192b082b08192b08, 0x192b082b192b0808,
    0x192b190808080808, 0x192b190808081919, 0x192b191908190808, 0x192b19190819082b,
    0x192b19192b081908, 0x192b2b081908082b, 0x2b08080808080808, 0x2b0808080808082b,
    0x2b08080808082b2b, 0x2b08080819080819, 0x2b0808082b08082b, 0x2b08081908081908,
    0x2b08081908192b08, 0x2b08081919080808, 0x2b08082b08190819, 0x2b08190808080819,
    0x2b08190808081908, 0x2b08190808190808, 0x2b08190808191919, 0x2b08190819080808,
    0x2b081908192b0808, 0x2b08191908080808, 0x2b0819191908192b, 0x2b0819192b191908,
    0x2b08192b08082b19, 0x2b08192b19080808, 0x2b08192b192b0808, 0x2b082b080808082b,
    0x2b082b1908081908, 0x2b082b2b08190819, 0x2b19080808081908, 0x2b19080808190808,
    0x2b190808082b1908, 0x2b19080819080808, 0x2b1908082b2b0819, 0x2b1908190819192b,
    0x2b1908192b080808, 0x2b19082b19081919, 0x2b19190808080808, 0x2b191908082b082b,
    0x2b19190819081908, 0x2b19191919190819, 0x2b192b082b080819, 0x2b192b19082b0808,
    0x2b2b08080808082b, 0x2b2b080819190808, 0x2b2b08082b081919, 0x2b2b081908082b19,
    0x2b2b082b08080808, 0x2b2b190808192b08, 0x2b2b2b0819190808, 0x2b2b2b1908081908,
};

#define NR0 4
#define NSG 2

/* Both variants compute the same thing: a gate/up pair matvec over IQ2_XXS
 * weights, which is what a V4.1 expert costs at decode time. */
template<int VARIANT>
static void iq2_pair(device const block_iq2_xxs *xg, device const block_iq2_xxs *xu,
                     device const float *y, device float *outg, device float *outu,
                     constant uint &nb32, constant uint &row_blocks,
                     threadgroup char *shmem, uint3 tgpig, ushort tiisg, ushort sgitg) {
    threadgroup ulong *svalues = (threadgroup ulong *)shmem;
    threadgroup uchar *ssigns  = (threadgroup uchar *)(svalues + 256);
    {
        int nval = 4, pos = (32*sgitg + tiisg)*nval;
        for (int i = 0; i < nval; ++i) svalues[pos + i] = ds4_metal_iq2xxs_grid[pos + i];
        nval = 2; pos = (32*sgitg + tiisg)*nval;
        for (int i = 0; i < nval; ++i) ssigns[pos+i] = ds4_metal_ksigns_iq2xs[pos+i];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const int first_row = (tgpig.x * NSG + sgitg) * NR0;
    float yl[32];
    float sumg[NR0] = {0.f}, sumu[NR0] = {0.f};
    device const float *y4 = y + 32 * tiisg;
    for (uint ib32 = tiisg; ib32 < nb32; ib32 += 32) {
        for (short i = 0; i < 32; ++i) yl[i] = y4[i];
        const uint ibl = ib32 / (QK_K/32), ib = ib32 % (QK_K/32);
        device const block_iq2_xxs *xgr = xg + first_row*row_blocks + ibl;
        device const block_iq2_xxs *xur = xu + first_row*row_blocks + ibl;
        device const ushort *qg = xgr->qs + 4*ib;
        device const ushort *qu = xur->qs + 4*ib;
        device const half *dhg = &xgr->d;
        device const half *dhu = &xur->d;
        for (short row = 0; row < NR0; row++) {
            device const uchar *aux8g = (device const uchar *)qg;
            device const uchar *aux8u = (device const uchar *)qu;
            const uint aux32g = qg[2] | (qg[3] << 16);
            const uint aux32u = qu[2] | (qu[3] << 16);
            const float dg = (float)dhg[0] * (0.5f + (aux32g >> 28));
            const float du = (float)dhu[0] * (0.5f + (aux32u >> 28));
            float sg = 0, su = 0;
            if (VARIANT == 2) {
                for (short l = 0; l < 4; ++l) {
                    const ulong gg = svalues[aux8g[l]], gu = svalues[aux8u[l]];
                    const uchar signg = ssigns[(aux32g >> 7*l) & 127];
                    const uchar signu = ssigns[(aux32u >> 7*l) & 127];
                    const uchar4 gg0 = as_type<uchar4>((uint)gg),  gg1 = as_type<uchar4>((uint)(gg >> 32));
                    const uchar4 gu0 = as_type<uchar4>((uint)gu),  gu1 = as_type<uchar4>((uint)(gu >> 32));
                    const float4 y0 = float4(yl[8*l+0], yl[8*l+1], yl[8*l+2], yl[8*l+3]);
                    const float4 y1 = float4(yl[8*l+4], yl[8*l+5], yl[8*l+6], yl[8*l+7]);
                    const uint4 sh = uint4(0u, 1u, 2u, 3u);
                    const uint4 mg0 = ((uint4((uint)signg) >> sh) & 1u) << 31;
                    const uint4 mg1 = ((uint4((uint)signg >> 4) >> sh) & 1u) << 31;
                    const uint4 mu0 = ((uint4((uint)signu) >> sh) & 1u) << 31;
                    const uint4 mu1 = ((uint4((uint)signu >> 4) >> sh) & 1u) << 31;
                    const float4 pg0 = as_type<float4>(as_type<uint4>(y0 * float4(gg0)) ^ mg0);
                    const float4 pg1 = as_type<float4>(as_type<uint4>(y1 * float4(gg1)) ^ mg1);
                    const float4 pu0 = as_type<float4>(as_type<uint4>(y0 * float4(gu0)) ^ mu0);
                    const float4 pu1 = as_type<float4>(as_type<uint4>(y1 * float4(gu1)) ^ mu1);
                    const float4 pg = pg0 + pg1, pu = pu0 + pu1;
                    sg += pg.x + pg.y + pg.z + pg.w;
                    su += pu.x + pu.y + pu.z + pu.w;
                }
            } else if (VARIANT == 1) {
                for (short l = 0; l < 4; ++l) {
                    const ulong gg = svalues[aux8g[l]], gu = svalues[aux8u[l]];
                    const uint gg_lo = (uint)gg, gg_hi = (uint)(gg >> 32);
                    const uint gu_lo = (uint)gu, gu_hi = (uint)(gu >> 32);
                    const uchar signg = ssigns[(aux32g >> 7*l) & 127];
                    const uchar signu = ssigns[(aux32u >> 7*l) & 127];
                    for (short j = 0; j < 4; ++j) {
                        const float v0 = yl[8*l + j], v1 = yl[8*l + j + 4];
                        const float g0 = v0 * (float)((gg_lo >> (8*j)) & 0xffu);
                        const float g1 = v1 * (float)((gg_hi >> (8*j)) & 0xffu);
                        const float u0 = v0 * (float)((gu_lo >> (8*j)) & 0xffu);
                        const float u1 = v1 * (float)((gu_hi >> (8*j)) & 0xffu);
                        sg += ((signg >> j) & 1) ? -g0 : g0;
                        sg += ((signg >> (j+4)) & 1) ? -g1 : g1;
                        su += ((signu >> j) & 1) ? -u0 : u0;
                        su += ((signu >> (j+4)) & 1) ? -u1 : u1;
                    }
                }
            } else {
                for (short l = 0; l < 4; ++l) {
                    const threadgroup uchar *gridg = (const threadgroup uchar *)(svalues + aux8g[l]);
                    const threadgroup uchar *gridu = (const threadgroup uchar *)(svalues + aux8u[l]);
                    const uchar signg = ssigns[(aux32g >> 7*l) & 127];
                    const uchar signu = ssigns[(aux32u >> 7*l) & 127];
                    for (short j = 0; j < 8; ++j) {
                        const float v = yl[8*l + j];
                        sg += v * gridg[j] * (signg & ds4_metal_kmask_iq2xs[j] ? -1.f : 1.f);
                        su += v * gridu[j] * (signu & ds4_metal_kmask_iq2xs[j] ? -1.f : 1.f);
                    }
                }
            }
            sumg[row] += dg * sg;
            sumu[row] += du * su;
            dhg += row_blocks * sizeof(block_iq2_xxs)/2;
            dhu += row_blocks * sizeof(block_iq2_xxs)/2;
            qg  += row_blocks * sizeof(block_iq2_xxs)/2;
            qu  += row_blocks * sizeof(block_iq2_xxs)/2;
        }
        y4 += 32 * 32;
    }
    for (int row = 0; row < NR0; ++row) {
        const float sg = simd_sum(sumg[row]), su = simd_sum(sumu[row]);
        if (tiisg == 0) { outg[first_row + row] = sg * 0.25f; outu[first_row + row] = su * 0.25f; }
    }
}

kernel void iq2_pair_base(device const block_iq2_xxs *xg [[buffer(0)]],
        device const block_iq2_xxs *xu [[buffer(1)]], device const float *y [[buffer(2)]],
        device float *outg [[buffer(3)]], device float *outu [[buffer(4)]],
        constant uint &nb32 [[buffer(5)]], constant uint &row_blocks [[buffer(6)]],
        threadgroup char *shmem [[threadgroup(0)]], uint3 tgpig [[threadgroup_position_in_grid]],
        ushort tiisg [[thread_index_in_simdgroup]], ushort sgitg [[simdgroup_index_in_threadgroup]]) {
    iq2_pair<0>(xg, xu, y, outg, outu, nb32, row_blocks, shmem, tgpig, tiisg, sgitg);
}
kernel void iq2_pair_vec4(device const block_iq2_xxs *xg [[buffer(0)]],
        device const block_iq2_xxs *xu [[buffer(1)]], device const float *y [[buffer(2)]],
        device float *outg [[buffer(3)]], device float *outu [[buffer(4)]],
        constant uint &nb32 [[buffer(5)]], constant uint &row_blocks [[buffer(6)]],
        threadgroup char *shmem [[threadgroup(0)]], uint3 tgpig [[threadgroup_position_in_grid]],
        ushort tiisg [[thread_index_in_simdgroup]], ushort sgitg [[simdgroup_index_in_threadgroup]]) {
    iq2_pair<2>(xg, xu, y, outg, outu, nb32, row_blocks, shmem, tgpig, tiisg, sgitg);
}
kernel void iq2_pair_regs(device const block_iq2_xxs *xg [[buffer(0)]],
        device const block_iq2_xxs *xu [[buffer(1)]], device const float *y [[buffer(2)]],
        device float *outg [[buffer(3)]], device float *outu [[buffer(4)]],
        constant uint &nb32 [[buffer(5)]], constant uint &row_blocks [[buffer(6)]],
        threadgroup char *shmem [[threadgroup(0)]], uint3 tgpig [[threadgroup_position_in_grid]],
        ushort tiisg [[thread_index_in_simdgroup]], ushort sgitg [[simdgroup_index_in_threadgroup]]) {
    iq2_pair<1>(xg, xu, y, outg, outu, nb32, row_blocks, shmem, tgpig, tiisg, sgitg);
}

/* ---- A vertical slice of one V4.1 streaming MoE layer -------------------
 *
 * router -> GPU cache table validation -> hit expert execution -> miss record
 *
 * The point is the control structure, not the arithmetic. Both paths run the
 * identical expert kernel over identical bytes; they differ only in whether
 * the selected ids leave the GPU. The host-driven path commits, waits, reads
 * them and dispatches. The resident path keeps them in GPU memory, validates
 * them against the address table on the GPU, executes the lanes that hit and
 * records the ones that miss for the host to repair later.
 */

struct proto_args { uint n_total_expert; uint n_selected; uint row_blocks; uint nb32; };

/* The ids originate on the GPU, as they do in the real layer: the resident
 * path must never be able to see them on the host. */
kernel void proto_router_topk(device const float *scores [[buffer(0)]],
        device int *ids [[buffer(1)]], constant proto_args &a [[buffer(2)]],
        uint tid [[thread_position_in_threadgroup]]) {
    if (tid != 0) return;
    for (uint k = 0; k < a.n_selected; ++k) {
        int best = -1; float bv = -1e30f;
        for (uint e = 0; e < a.n_total_expert; ++e) {
            bool taken = false;
            for (uint j = 0; j < k; ++j) if (ids[j] == (int)e) taken = true;
            if (!taken && scores[e] > bv) { bv = scores[e]; best = (int)e; }
        }
        ids[k] = best;
    }
}

/* status[0] = miss mask, status[1] = 1 when every lane hit, status[2] = misses.
 * The host reads this only when it decides to, not once a layer. */
kernel void proto_validate(device const int *ids [[buffer(0)]],
        device const ulong *gate_addrs [[buffer(1)]],
        device const ulong *up_addrs [[buffer(2)]],
        device atomic_uint *status [[buffer(3)]],
        device int *miss_ids [[buffer(4)]],
        constant proto_args &a [[buffer(5)]],
        uint tid [[thread_position_in_threadgroup]]) {
    if (tid >= a.n_selected) return;
    const int id = ids[tid];
    const bool hit = id >= 0 && (uint)id < a.n_total_expert &&
                     gate_addrs[id] != 0 && up_addrs[id] != 0;
    if (!hit) {
        atomic_fetch_or_explicit(&status[0], 1u << tid, memory_order_relaxed);
        atomic_fetch_add_explicit(&status[2], 1u, memory_order_relaxed);
        miss_ids[tid] = id;
    } else {
        miss_ids[tid] = -1;
    }
}

kernel void proto_seal(device atomic_uint *status [[buffer(0)]],
        uint tid [[thread_position_in_threadgroup]]) {
    if (tid != 0) return;
    const uint miss = atomic_load_explicit(&status[0], memory_order_relaxed);
    atomic_store_explicit(&status[1], miss == 0u ? 1u : 0u, memory_order_relaxed);
}

/* One threadgroup slice per (selected lane, output row group). A lane whose
 * expert is not in the table writes nothing and costs nothing: that is the
 * miss being skipped rather than waited for. */
kernel void proto_expert(device const int *ids [[buffer(0)]],
        device const ulong *gate_addrs [[buffer(1)]],
        device const ulong *up_addrs [[buffer(2)]],
        device const float *y [[buffer(3)]],
        device float *outg [[buffer(4)]], device float *outu [[buffer(5)]],
        constant proto_args &a [[buffer(6)]],
        constant uint &out_stride [[buffer(7)]],
        threadgroup char *shmem [[threadgroup(0)]],
        uint3 tgpig [[threadgroup_position_in_grid]],
        ushort tiisg [[thread_index_in_simdgroup]],
        ushort sgitg [[simdgroup_index_in_threadgroup]]) {
    const uint slot = tgpig.z;
    tgpig.z = 0;
    const int id = ids[slot];
    if (id < 0 || (uint)id >= a.n_total_expert) return;
    const ulong ga = gate_addrs[id], ua = up_addrs[id];
    if (ga == 0 || ua == 0) return;              /* miss: skipped, not awaited */
    device const block_iq2_xxs *xg = reinterpret_cast<device const block_iq2_xxs *>(ga);
    device const block_iq2_xxs *xu = reinterpret_cast<device const block_iq2_xxs *>(ua);
    iq2_pair<0>(xg, xu, y, outg + slot * out_stride, outu + slot * out_stride,
                a.nb32, a.row_blocks, shmem, tgpig, tiisg, sgitg);
}
