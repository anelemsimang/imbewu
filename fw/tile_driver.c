/* tile_driver.c - driver program for the Imbewu tile (runs on its RISC-V core)
 *
 * Plain language: from a short description of the work - how many weight
 * groups, how many batches of activations per group, and the matrix sizes -
 * this program works out every command for the tile (where each input lies
 * in main memory, how big it is, where the answer goes, which weight slot),
 * writes the commands into the tile, starts it, and waits for it to finish.
 * The memory layout it assumes is the "driver contract" shared with the
 * software that prepares main memory (tools/gen_tile_v2_vectors.py, layout v3):
 *   per command: A, A scales, then (if it brings weights) B, B scales;
 *   answers from OUT_BASE, one C word = 4 memory words.
 *
 * The work description comes from compile-time settings (-D...), e.g.
 *   -DGRID=4 -DGROUPS=3 -DPER=5 -DMT=1 -DNT=3 -DKB=3 -DFA=1 -DFB=2
 */
#include <stdint.h>

#ifndef GRID
#define GRID 4
#endif
#ifndef GROUPS
#define GROUPS 3
#endif
#ifndef PER
#define PER 5
#endif
#ifndef MT
#define MT 1
#endif
#ifndef NT
#define NT 3
#endif
#ifndef KB
#define KB 3
#endif
#ifndef FA
#define FA 1
#endif
#ifndef FB
#define FB 2
#endif
#ifndef RELOAD               /* 1: every command fetches its weights again */
#define RELOAD 0
#endif
#ifndef ONE_SLOT             /* 1: every group uses weight slot 0 */
#define ONE_SLOT 0
#endif
#define IN_BASE  0x00000u
#define OUT_BASE 0x40000u

#define REG(off) (*(volatile uint32_t *)(0x10000000u + (off)))

/* Pack fields, most significant first, into 7 words of 32 bits (200 bits). */
static uint32_t cmd[7];
static int pos;                      /* bits still free below the current one */
static void put(uint32_t value, int width)     /* width <= 20 */
{
    pos -= width;                                 /* field occupies bits pos .. pos+width-1 */
    value &= (1u << width) - 1u;
    int w = pos >> 5, b = pos & 31;
    cmd[w] |= value << b;                         /* low part */
    if (b + width > 32)
        cmd[w + 1] |= value >> (32 - b);          /* part that spills into the next word */
}

int main(void)
{
    const int pair  = (FA == 2 && FB == 2);       /* two FP4 numbers per lane */
    const uint32_t beats = (pair ? 16u : 32u) * KB;
    const uint32_t bb    = pair ? 16u : 32u;
    const uint32_t n_a = MT * beats, n_sa = MT * KB;
    const uint32_t n_b = NT * beats, n_sb = NT * KB;
    const uint32_t n_c = MT * GRID * NT;
    uint32_t in = IN_BASE, out = OUT_BASE;
    int k = 0;

    for (int g = 0; g < GROUPS; g++) {
        for (int p = 0; p < PER; p++, k++) {
            int load_b = RELOAD || p == 0;
            for (int w = 0; w < 7; w++) cmd[w] = 0;
            pos = 200;
            put(in, 20);        put(n_a, 16);      put(load_b ? n_b : 0, 16);
            put(n_sa, 12);      put(load_b ? n_sb : 0, 12);
            put(out, 20);       put(n_c, 16);      put(MT, 8);  put(NT, 8);
            put(beats, 16);     put(bb, 16);       put(KB, 16);
            put(FA, 2);         put(FB, 2);
            put(ONE_SLOT ? 0 : (g & 1), 1);  put(0, 19);
            for (int w = 0; w < 7; w++) REG(4 * w) = cmd[w];
            REG(0x20) = k;                         /* write it into slot k */
            in  += n_a + n_sa + (load_b ? n_b + n_sb : 0);
            out += 4 * n_c;
        }
    }
    REG(0x24) = k;                                 /* number of commands */
    REG(0x28) = 1;                                 /* start */
    while (!(REG(0x2C) & 2u))                      /* wait until done */
        ;
    return 0x600D0000u | (uint32_t)k;              /* "good" + commands run */
}
