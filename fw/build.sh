#!/bin/sh
# Build the tile driver for the RISC-V core: fw/build.sh OUT_HEX [-Dsetting=value ...]
# Needs clang and ld.lld (LLVM) with the RISC-V target.
set -e
OUT=$1; shift
D=$(dirname "$0")
clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -O2 -ffreestanding \
  -nostdlib -fno-builtin -fuse-ld=lld -T "$D/link.ld" "$@" \
  "$D/start.S" "$D/tile_driver.c" -o "$OUT.elf"
llvm-objcopy -O binary "$OUT.elf" "$OUT.bin"
python3 -c "
import sys
d = open('$OUT.bin', 'rb').read()
d += bytes((-len(d)) % 4)
open('$OUT', 'w').writelines(f'{int.from_bytes(d[i:i+4], \"little\"):08x}\n' for i in range(0, len(d), 4))
print(f'firmware: {len(d)} bytes')"
