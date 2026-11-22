/* link.ld - program and data in the 16 KB RAM at address 0 */
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x3000 }
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
    .rodata : { *(.rodata*) *(.srodata*) } > RAM
    .data : { *(.data*) *(.sdata*) } > RAM
    .bss : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
}
