# Learning notes

Plain-language explanations of everything used in this project, added as we go.

## What a chip is
A slab of silicon covered in billions of microscopic switches (transistors).
Each is on or off, read as 1 or 0. Wired together, they add, multiply and store
numbers. AI is mostly multiplication, done in enormous quantities.

## The five stages of making a chip
1. **Architecture**: what the chip does and how its parts are arranged (the floor plan).
2. **Design (RTL)**: describing the circuit in a hardware language such as Verilog.
3. **Verification**: testing the design in simulation, thousands to millions of
   times. Most of the effort goes here, because a bug in silicon can't be patched.
4. **Physical layout**: software turns the design into transistors and wires,
   producing the "tapeout" file a factory accepts.
5. **Fabrication**: a factory (fab) such as TSMC prints the chip.

Most chip companies, including Nvidia, are **fabless**: they design, and a fab
manufactures. That's the model for Imbewu.

## Simulation
Running the chip design as software on an ordinary computer, to see what it
would do. A **testbench** is a program that feeds the design inputs and checks
every answer against a known-correct calculation. A **waveform** is a
recording of every signal over time, used to find bugs (like a heart monitor
for the chip).

## Synthesis and gate count
**Synthesis** (our tool: Yosys) converts a design into basic logic gates. The
gate count tells us roughly how big, and therefore how expensive and
power-hungry, the circuit will be.

## The clock
A chip does its work in steps, triggered by a clock that ticks millions or
billions of times per second. On each tick, every part of the chip takes its
next step at the same moment.

## MAC: multiply-accumulate
Multiply two numbers and add the result to a running total. It is the basic
building block of every AI chip. Our version: `rtl/mac.v`.

## INT8 and INT32
Number formats. INT8 is a whole number from -128 to 127, stored in 8 bits.
AI inference often uses INT8 because small numbers mean smaller, faster,
lower-power circuits. Results are kept in INT32 (up to about +/-2 billion)
so adding many products together doesn't overflow.

## Matrix multiplication
A matrix is a grid of numbers. Multiplying two matrices means, for every
result cell, taking a row from the first and a column from the second,
multiplying them pair by pair and adding up the products. Nearly all the work
inside an AI model (including large language models) is this operation,
repeated billions of times.

## Systolic array
Our matrix engine (`rtl/matmul4.v`). A grid of small MAC cells. Numbers from
the first matrix flow in from the left, numbers from the second flow in from
the top, and each cell multiplies whatever meets it, adds it to its own total,
and passes the numbers on to its neighbours. The rows and columns enter
staggered in time ("skewed") so the right pairs meet in the right cell.

It's called "systolic" after the heart: data pulses through the grid in
rhythm. The advantage is that each number is fetched from memory once and then
reused by every cell it passes, and fetching from memory is what costs the
most energy in a chip. Google's TPU uses this idea at 128x128 and larger.

Our 4x4 version finishes a full 4x4 multiplication (64 multiplications) in
12 clock ticks, with 16 cells working at the same time.
