#!/usr/bin/env python3
"""Cost per WORKING chip, with and without spare tiles (W6, goal G5).

Plain language: a wafer of silicon costs the same however many of its chips
turn out faulty. Defects land at random; a chip with a defect in a part it
cannot do without is thrown away. If the chip is made of many identical
tiles and a few may be switched off (spare tiles, built and tested in
rtl/cluster.v), a defect inside a tile no longer kills the chip. This
estimates how much that lowers the cost of each chip that can be sold.

Method (textbook): defects are random (Poisson) with density D per mm^2.
  - the shared part of the chip (memory interfaces, links, control): must
    have no defect: probability exp(-D * A_shared)
  - each tile works with probability p = exp(-D * A_tile); with S spares the
    chip is good if at most S of its T + S tiles are faulty (binomial).
  - chips per wafer: the usual formula for a round wafer.
Every number below is an ASSUMPTION, stated and easy to change. Defect
density 0.001 per mm^2 is the figure reported for TSMC 5 nm in the Cerebras
article (docs/research/); wafer price is a public estimate. Real yield
also suffers from clustered defects and parametric failures (not modelled):
this is a first estimate.

Usage: python3 tools/yield_model.py
"""
import math

WAFER_MM = 300
WAFER_USD = 17000          # ASSUMPTION: public estimates for a 5 nm-class wafer
RAND_PER_USD = 18.0        # ASSUMPTION: exchange rate, for G5 (cost per rand)


def chips_per_wafer(area):
    d = WAFER_MM
    return int(math.pi * (d / 2) ** 2 / area - math.pi * d / math.sqrt(2 * area))


def good_fraction(D, a_shared, a_tile, tiles, spares):
    p = math.exp(-D * a_tile)
    n = tiles + spares
    tiles_ok = sum(math.comb(n, k) * (1 - p) ** k * p ** (n - k) for k in range(spares + 1))
    return math.exp(-D * a_shared) * tiles_ok


def study(D=0.001, die=600.0, tile_share=0.6, tiles=256):
    """die: area of the chip WITHOUT spares (mm^2); tile_share: part of it in tiles."""
    a_tile = die * tile_share / tiles
    a_shared = die * (1 - tile_share)
    rows = []
    for spares in (0, 2, 4, 8, 16):
        area = die + spares * a_tile
        y = good_fraction(D, a_shared, a_tile, tiles, spares)
        n = chips_per_wafer(area)
        good = n * y
        rows.append(dict(spares=spares, area=area, per_wafer=n, yield_=y, good=good,
                         usd=WAFER_USD / good))
    return a_tile, a_shared, rows


def main():
    print(__doc__.split("Usage")[0].strip().splitlines()[0])
    for D in (0.001, 0.002):
        for die, share in ((600.0, 0.6), (300.0, 0.6)):
            a_tile, a_shared, rows = study(D, die, share)
            print(f"\nDefects {D}/mm^2, chip {die:.0f} mm^2 without spares, {100 * share:.0f}% in 256 tiles "
                  f"({a_tile:.2f} mm^2 each), shared part {a_shared:.0f} mm^2")
            print("| Spare tiles | Chip area mm^2 | Chips per wafer | Working | Good chips per wafer | "
                  "Silicon cost per good chip (USD) | (rand) |")
            print("|---|---|---|---|---|---|---|")
            base = rows[0]["usd"]
            for r in rows:
                print(f"| {r['spares']} | {r['area']:.0f} | {r['per_wafer']} | {100 * r['yield_']:.0f}% | "
                      f"{r['good']:.1f} | {r['usd']:.0f} ({100 * (r['usd'] / base - 1):+.0f}%) | "
                      f"R{r['usd'] * RAND_PER_USD:,.0f} |")
    print("\nWafer price and exchange rate are assumptions; silicon only (no packaging, HBM, test).")


if __name__ == "__main__":
    main()
