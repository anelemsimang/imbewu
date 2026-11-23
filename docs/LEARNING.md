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
Our matrix engine (`rtl/systolic_array.v`). A grid of small MAC cells. Numbers from
the first matrix flow in from the left, numbers from the second flow in from
the top, and each cell multiplies whatever meets it, adds it to its own total,
and passes the numbers on to its neighbours. The rows and columns enter
staggered in time ("skewed") so the right pairs meet in the right cell.

It's called "systolic" after the heart: data pulses through the grid in
rhythm. The advantage is that each number is fetched from memory once and then
reused by every cell it passes, and fetching from memory is what costs the
most energy in a chip. Google's TPU uses this idea at 128x128 and larger.

The grid size is a setting (N), so one design builds any size. Our 4x4 version finishes a full 4x4 multiplication (64 multiplications) in
12 clock ticks, with 16 cells working at the same time.

## Parameters
A setting in a chip design that changes its size or behaviour without
rewriting it. Our systolic engine has one, N, the grid size. Real chips use
the same trick: one well-tested design, built at whatever size the product needs.

## Utilisation
The share of time the chip's calculating cells are actually calculating. Our
engine currently sits at about 33%: for each job, the grid has to fill with
data and then empty out, and cells at the edges wait during that time. Idle
cells still use power and still cost silicon, so raising utilisation is one
of the most important things in AI-chip design. Nvidia and Google put huge
effort into keeping their cores busy.

## Streaming (pipelining)
Our version-2 engine works like a factory line. Instead of waiting for one job
to leave the grid before starting the next, the next job enters right behind
it. Each number carries two small tags: "valid" (this is real data) and "last"
(this is the final number of the job). When a cell sees "last", it parks its
finished answer and starts the next job's total from zero on the very next
tick. Result: cells are busy 99.5% of the time instead of 33%, three times the
work from almost the same circuit. Every serious AI chip relies on this idea.

## Throughput vs latency
**Latency** is how long one job takes from start to finish. **Throughput** is
how many jobs finish per second. Streaming barely changes latency but triples
throughput. For a data centre serving millions of users, throughput is usually
what pays the bills; for one person chatting, latency is what they feel.
Goal G4 is about balancing both.

## Floating-point numbers (FP8, FP4)
Whole numbers (INT8) can't hold fractions or very large and very small values
at the same time. **Floating-point** numbers work like scientific notation:
a few digits plus a power of two, e.g. 1.5 x 2^3 = 12. The fewer bits, the
smaller and faster the circuit, but the rougher the number:
- **FP8 (E4M3)**: 8 bits, values from about 0.002 up to 448.
- **FP4 (E2M1)**: 4 bits, only 16 possible values: 0, 0.5, 1, 1.5, 2, 3, 4, 6
  (and their negatives). Two fit in the space of one FP8 number, so the chip
  can do twice as many per tick.

## Microscaling (MX)
How can AI work with numbers as rough as FP4? Trick: groups of numbers (a
"block", usually 32) share one extra scale factor, a power of two. The block's
numbers say "how big relative to each other"; the shared scale says "how big
overall". This open standard from the Open Compute Project (backed by AMD,
Arm, Intel, Meta, Microsoft, Nvidia, Qualcomm) is what Imbewu follows.

## Exact accumulation
Our engine adds every product into a wide 48-bit total whose smallest step is
tiny enough to hold any FP8 product exactly. So no rounding happens inside a
block, and results are bit-for-bit predictable. That makes the chip easier to
verify, and trustworthy for training, where small rounding errors can pile up.

## Independent reference model
To test a chip you need the correct answers from somewhere else. If the same
person writes the design and the answer-checker in the same way, both can share
the same mistake. So our expected answers come from a separate Python program
using a well-known public library (ml_dtypes). Two independent routes agreeing
on 336,000 answers is strong evidence.

## Perplexity
The standard accuracy score for a language model. The model reads real text
and, at each word, guesses what comes next. Perplexity is roughly how many
words it is "choosing between" on average. Lower is better. If rounding the
numbers to FP8 moves perplexity from 13.8 to 14.3, the model got slightly
less sure of itself; a jump to 33 means it got much worse.

## Quantisation (and "fake quantisation")
Quantisation means storing numbers with fewer bits (for example FP4 instead
of FP32). It saves memory, energy and silicon, but adds rounding error. To
measure the damage before any chip exists, we run the model normally on a
computer but round every number to the chip's format just before each
multiply. That gives the same answers the chip would give (we checked this
exactly on one layer) without needing the chip.

## Weights and activations
Weights are the numbers the model learned during training; they are fixed.
Activations are the numbers flowing through the model while it reads your
text; they change every time. Activations usually have a few very large
values, so they suffer more from tiny formats like FP4. That is why
"FP4 weights, FP8 activations" is a common compromise.

## Formal verification
A normal test tries some inputs and checks the answers. Formal verification
hands the design and a list of rules to a "solver" program, which reasons
about every possible input at once. It either proves the rule can never be
broken, or produces the exact sequence of inputs that breaks it (a
counter-example). Chip companies use it because some bugs only appear in
rare situations that random tests never hit.

## Proof by induction
Like dominoes. Show the first domino falls (the rules hold for the first
ticks after reset: the "base case"). Then show that any falling domino
knocks over the next (if the rules held up to now, they hold on the next
tick: the "induction step"). Then every domino falls: the rules hold
forever. Helper rules ("invariants") are often needed so the solver can
see why each step follows.

## Mutation testing
Testing the tests. We deliberately break the design in small ways and
check that the tests notice. A test that still passes on a broken design is
not protecting us.

## Roofline (which part of the chip is the bottleneck)
Every task needs some calculating and some fetching of data from memory.
If the chip can calculate faster than memory can deliver, the task is
"memory bound": buying more calculators won't help. If memory is fast enough
and the calculators are busy, it is "compute bound". A roofline model just
works out both times and takes the bigger one.

## Prefill and decode
A language model reads your whole prompt at once ("prefill"): lots of
calculating per number fetched, so it is compute bound. Then it writes its
answer one word at a time ("decode"): for every single word it must read
all of its weights from memory again, so it is memory bound. This is why
memory bandwidth (goal G3) decides how fast a chatbot answers.

## KV cache
While answering, the model keeps notes on everything it has read so far
(the "key/value cache"), so it doesn't re-read the whole conversation for
each new word. These notes grow with the conversation length and the number
of users, and must also be read from memory for every word.

## FP32 and rounding once
FP32 is the standard 32-bit floating-point format (about 7 decimal digits).
Our cells add each block of 32 products exactly, then add that block's
total into an FP32 running total. Only that last step rounds, and it
rounds once, to the nearest FP32 value (on an exact tie, to the "even"
one, which avoids drifting up or down). Rounding twice in a row can give
a slightly different answer, which is why the design avoids it.

## Overflow, infinity and subnormals
If a total is too big for FP32 it becomes "infinity", and stays that way,
which is easy to detect. Numbers that are too small for the normal range
are kept with reduced precision ("subnormals") instead of being thrown
away. Our tests deliberately hit both cases.

## Area versus correctness
A first design is built to be correct and easy to check. It is then made
smaller and faster while the same tests keep proving it is still correct.
Version 4 is correct but large; making it small is the next step.

## Tiling
The engine computes one small square piece (a "tile") of the answer at a
time. A big matrix multiply is cut into many tiles, and a controller feeds
them to the engine one after another without pauses. Like tiling a floor:
the same small square, laid many times, covers any size of room.

## SRAM and data layout
SRAM is the fast memory on the chip itself. It can deliver one wide word
per tick. The compiler arranges the numbers in memory so that each word
holds exactly what the engine needs in that tick; arranging data well is
as important for speed as the engine itself.

## Standard cells, PDKs and process nodes
A factory (foundry) publishes a "process design kit" (PDK): the rules and a
library of ready-made logic gates ("standard cells") with their exact size
and speed. Turning our design into those gates gives a real area in square
micrometres and real gate delays. SKY130 is an open 130 nm process (real
chips are made in it); the 45 nm library is an open teaching library. Data-
centre AI chips use 3-5 nm processes, whose kits are only available under
licence from the foundry.

## Clock speed and the "longest path"
Every tick, signals must travel from one storage register through the
logic to the next register before the next tick starts. The slowest such
path sets the fastest clock: a 2.5 ns path allows about 400 MHz. To go
faster, long paths are cut into shorter steps with registers in between
("pipelining"), which is what we did to the shared FP32 adder.

## Ripple versus parallel adders
A simple adder passes the carry from digit to digit, like adding by hand:
48 digits means 48 steps in a row. A parallel ("Kogge-Stone") adder works
out all the carries at once in about 6 steps, using more gates. Real chips
use parallel adders on their critical paths.

## Double buffering
Like a chef with two chopping boards: while cooking from one board, an
assistant prepares the next ingredients on the other. If the assistant is
fast enough, the chef never waits. The tile's memory is split in two
halves for exactly this reason.

## Arithmetic intensity
How many calculations each number fetched from memory feeds. Big matrix
multiplies reuse every number many times (high intensity), so compute is
the limit; small ones barely reuse anything (low intensity), so memory is
the limit, however fast the engine.

## Control processor and driver
The tile's engine and data mover only follow orders. A small general-
purpose processor (here PicoRV32, an open RISC-V design) runs a "driver"
program that turns a short description of the work ("3 layers, 5 batches
each, these sizes") into the exact list of orders: where every input sits
in memory, how big it is, where the answer goes. Data-centre chips work
the same way: tiny processors next to the engines, so the host computer
only hands out the work.

## RISC-V
An open, royalty-free instruction set: the "language" a processor
understands. Anyone may build a RISC-V processor without a licence fee,
which is why it suits a new chip company and national sovereignty goals.

## The vector unit and softmax
Not everything in a language model is a matrix multiply. Softmax turns a
row of scores into probabilities that add up to 1 (used in attention);
normalisation (RMSNorm) rescales each row so numbers stay in a sensible
range; SiLU is the "activation" that lets the model represent curved,
non-linear patterns. These work on rows of numbers one element at a time,
so they run on a vector unit: a row of simple FP32 calculators side by
side, one per engine column.

## Building exp and 1/x from add and multiply
Hardware for exp() or division is large. Instead, exp(x) is written as
2^(whole part) x 2^(fraction), where 2^(whole part) is just an exponent
and 2^(fraction) a short polynomial (7 multiply-adds). 1/x starts from a
rough guess (a famous bit trick) and is improved three times with
Newton's method, each step doubling the number of correct digits.

## Attention, in one paragraph
For every word, the model asks "which earlier words matter for me?". Each
word has a query (Q) and a key (K); multiplying Q by K for every pair gives
a score; softmax turns the scores into weights that add up to 1; the
weights then mix the words' values (V). Our tests showed the scoring step
(Q x K) is the delicate one: it needs 16-bit numbers (we chose MXINT16:
16-bit whole numbers sharing a scale per block), while the mixing step is
fine with 8-bit ones.

## Perplexity of a whole model "on the chip"
Simulating every gate of the chip for a whole model would take days, so we
copy the chip's arithmetic exactly in fast software, after checking the
copy against the hardware. That lets us run a real language model end to
end "as the chip would" and see how good its answers still are.
