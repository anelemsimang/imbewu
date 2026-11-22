# start.S - first instructions after reset: set the stack, run main, report.
    .section .text.start
    .globl _start
_start:
    li   sp, 0x4000          # stack at the top of the 16 KB RAM
    call main
    li   t0, 0x10000040      # EXIT register: main's return value
    sw   a0, 0(t0)
1:  j    1b                  # stay here
