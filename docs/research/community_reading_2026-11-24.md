# Community reading, 2026-11-24 (founder-supplied PDFs)

Notes on material the founder collected from Reddit threads and the links in
them. Ideas only: no code or designs copied into Imbewu (D-003). Where a
claim is a source's opinion rather than an established fact, it says so.

## 1. "Designing AI Chip Software and Hardware" (a former Google TPU / Nvidia engineer; 154 pages)

Read: pages 1-105 (numerics, sparsity, array sizes, cycle tyranny, heat,
compression, workloads, HBM, parallelism, networks, co-design).
Not yet read: pages 106-154.

What it says that bears on Imbewu:

- **Numerics.** 8 bits is enough for inference if quantisation is done
  well; FP4 "sometimes, not always". The big arrays should use cheap
  numerics; the vector/scalar units can stay FP32 (softmax, normalisation).
  -> This is exactly Imbewu's split (MX in the engine, FP32 vector unit).
  He adds: an INT8-only engine is a real contender; supporting more formats
  helps sales because customers find ready-quantised models.
- **Structured sparsity (2:4).** Nvidia gets ~2x from it; TPUs lack it. BUT
  his later update: he is now "much more skeptical" after his own research
  (suspects unpublished negative results). -> Do NOT add sparsity now.
- **Mono-sized arrays are unbalanced.** Attention has small K (16-128),
  feed-forward large K (thousands). Proposal: one big array for FF plus
  several small arrays for attention on the same chip.
  -> Relevant: Imbewu's tile grid size is a parameter (N) already; a
  mixed-size cluster is a cheap experiment in our simulator.
- **Write hardware and software with the vector width as a parameter, and
  test at 2x2.** "How many in the industry are using this idea today? As far
  as I know, no one." -> Imbewu already does this (all tests at N = 2..16,
  formal proofs at 2..16). Worth stating in the pitch.
- **Cycle tyranny.** The control core must feed the array every cycle; a
  chip project "met disaster" because its control core could not keep up.
  Remedies: wide registers, queues before/after the array, and "systolic
  array DMAs" that stream data in/out without the core.
  -> Imbewu's tile already has this: the command list + data mover feed the
  engine without the RISC-V core (it only writes commands). The new
  post-processing stage (tile v4) also runs without the core.
- **Systolic arrays are hot.** TPUv3's array heat was underestimated; fixed
  partly by "compiler throttling" (gave 25% more clock). Needs a fast
  hardware power limiter, not only a temperature sensor.
  -> Add to W2/power model: hot-spot and fast throttling.
- **Compression.** Lossless (Huffman-style) compression on top of 8-bit
  numbers is largely unexplored; tables can also define custom lossy
  formats per layer. His own view, not measured. -> Possible research
  item; measure first.
- **Workloads.** Advice: do NOT make the first chip a training chip; start
  with inference. Prefill is compute-bound; decode is memory-bound and
  wants smaller arrays or more queries (GQA, speculative decoding, batching).
  -> Matches Imbewu (inference-first). Our perf model should report prefill
  and decode separately.
- **HBM.** Large HBM is mostly for KV cache; his opinion: much less is
  needed with smarter software (retrieval for old context, parallelism), so
  a startup could build a cheaper chip with little memory, if it also
  supplies the software. -> Directly relevant to G5 (cost per rand) and to
  the memory-choice decision; keep as an option, not a plan.
- **Parallelism and networks.** Within-layer parallelism needs a fast
  network; pipelining between layers mostly saves weight storage; network
  sums may need 16-32 bits. Proposes cheap 4x4 copper torus "donuts"
  joined by cheap routers. Recommends simulating parallelism, not only
  spreadsheets. -> Feeds Phase 3 (chip-to-chip). Our cluster simulator is
  the start of that.
- **Co-design and judgement.** Hardware should never fix a software-facing
  limit without the software side; beware experiments that ignore
  "derived consequences"; never trust a number without its context
  (benchmarks cherry-picked, cost ignored). -> Same discipline as our
  RESULTS.md "limits" sections.

## 2-5. Shorter PDFs

(Notes added below as each is reviewed.)

## 2. "Built an AI Accelerator and opensourced it" (Atik; r/chipdesign)

Repository named in the post: github.com/AhmedZeer/atik (Chisel, on
RocketChip RISC-V). Licence not checked; nothing copied (D-003).
- Claims: attention in hardware, BF16, FPGA prototype on AWS F2; speed-ups
  of 225x (attention), 96x TinyBERT, 50x ViT, 30x GPT-2 prefill. These are
  against a plain RocketChip CPU core ("RocketCore" in the chart), not a GPU
  or another accelerator, so they say little about competitiveness.
- Layout on SkyWater 130 nm, 3000 x 3000 (units not stated; likely microns,
  i.e. 3 mm x 3 mm). Author: "didn't claim tapeout ready". A commenter:
  "Chart is looking nice but the GDSII isn't ... if price is multiplied by
  some coefficient then what's the point?" (cost, not only speed).
- Most useful comment (experienced reader): use deep double buffering
  ("ping-pong SRAMs") so memory fetches overlap the multiplies; an 8x8 grid
  with a round-robin arbiter is fine, but at 16x16 "you'll be throttled by
  DMA read/write even if your compute itself is faster."
  -> Imbewu already double-buffers (tile v1 onward) and measured exactly
  this effect in the cluster (memory, not compute, sets the speed). Good
  outside confirmation of our direction.
- Author's reply: their earlier version with weights pinned and the next A
  fetched during the multiply "worked on Verilator" but "always faced
  negative time slack" on the FPGA, i.e. it simulated but failed timing.
  -> Lesson for us: simulation passing is not timing closure. Our W2
  timing estimates and the planned FPGA step matter.
- Author on AI tools: "vibe coding is never a solution. You need to know &
  understand what you are doing."

## 3. "Hop in, we are building OpenTPU!" (r/chipdesign)

Repository named in the post: github.com/FeSens/openTPU. Licence not
checked; nothing copied (D-003). The PDF has the post only (no comments).
- Whole stack in one repository: architecture, RTL, instruction set,
  simulator, compiler, host tools. Runs real models (Qwen3.5 named; the
  screenshot shows "LFM2.5-230M") on a Xilinx Kintex-7 PCIe FPGA card.
- Screenshot (FPGA board, small model): 100 MHz clock; about 30-40 tokens
  per second decode, 35 tokens/s prefill (small text, hard to read
  exactly); power "~7.6 W estimate"; 4 GB DDR3; a 128-wide array ("D=128").
- First ASIC layout routed with Nangate45 (the same open 45 nm library
  Imbewu's W2 estimates use); asks for help with floorplan and timing.
  The layout picture shows heavy wiring congestion around the array.
  -> Confirms the layout risk already noted in ROADMAP W2.
- Strongest lesson for Imbewu: a small team got a real language model
  generating text on a few-hundred-dollar FPGA card, with a status tool
  (utilisation, stalls, power, temperature). That is a far stronger demo
  for investors than simulation numbers alone. Supports moving the FPGA
  demo earlier (ROADMAP W1).

## 4. "100x Defect Tolerance: How Cerebras Solved the Yield Problem" (Cerebras blog, Jan 2025)

A company article (marketing, but the arithmetic is checkable).
- Yield (share of manufactured chips that work) falls with chip area, but
  can be rescued by building the chip from many identical cores and
  switching off the faulty ones. Shipping chips already do this: Nvidia
  H100 has 144 compute units, sells with 132 enabled (92%); A100 108 of 128.
- Smaller cores lose less area per defect. Their example (TSMC 5 nm,
  reported ~0.001 defects per mm^2): an H100-like core ~6.2 mm^2 vs a
  Cerebras core ~0.05 mm^2; on one wafer the GPU loses ~361 mm^2 to 59
  defects, the wafer-scale chip ~2.2 mm^2 to 46 defects.
- Needs spare cores plus a routing fabric that can steer around a dead core.
- Their own caveats: memory controllers, caches and the fabric are not
  made of tiny cores; clustered defects can still kill a chip.
-> Relevant to Imbewu: our design is already many identical tiles. Cheap
  to plan now: (a) spare tiles in the cluster and a way to mark a tile
  "disabled" so the arbiter and the compiler skip it; (b) a yield and
  cost-per-good-chip line in the cost model (G5). Wafer-scale itself is
  far beyond a startup's first chip; not proposed.

## 5. "The Design Process for Google's Training Chips: TPUv2 and TPUv3" (Norrie et al., IEEE Micro 2021)

Peer-reviewed paper by the TPU team (the design document's author is a
co-author). Read in full (9 pages + references).
- **"Great" versus "good enough".** They sorted all work into two buckets:
  do a great job on (1) build quickly, (2) high chip performance, (3) scale
  to many chips, (4) work for new workloads out of the box, (5) be cost
  effective; everything else only "good enough" (a split memory, an
  "inefficient" floor plan, a simple instruction memory). -> Imbewu's
  G1-G5 play the same role; worth adding an explicit "good enough" list so
  effort goes where it matters.
- **TPUv1 -> v2:** replaced fixed-function activation hardware with a
  programmable vector unit, kept the matrix unit as its co-processor, and
  added HBM (20x the bandwidth of v1's DDR3). -> Imbewu took the same path
  (vector unit inside the tile, D-023/D-024; programmable, not hard-wired).
- **Vector to matrix ratio.** TPUv2: 128 x 128 matrix unit (16K multiply-
  adds per cycle) beside 128 lanes x 8 "sublanes" = 1,024 vector ALUs, i.e.
  1 vector ALU per 16 multiply-adds. Imbewu: N lanes per N x N engine,
  i.e. 1 per N; at N = 16 that is the same 1:16 ratio. A useful check for
  sizing the vector unit at larger N.
- **Simplicity choices:** software-managed SRAM scratchpads (no caches),
  DMA to HBM with completion flags, result FIFOs from the matrix unit to
  simplify the compiler; the matrix unit can load its weights transposed.
  -> Imbewu uses the same scratchpad + data-mover style.
- **Area:** the matrix units are a small part of the chip; doubling them
  in TPUv3 cost little area and gave 1.8x average speed (peak 2.7x, limited
  by memory and network which grew only 1.3x). -> Same lesson as our
  cluster result: compute only pays if memory keeps up.
- **Numerics:** bfloat16 multiplies, FP32 accumulation; ~1.5x less energy
  than FP16 at 7 nm. Practitioners would not do extra work (loss scaling)
  to use FP16 -> formats must be easy to use, which supports Imbewu's
  compiler doing the MX rounding automatically.
- **Network:** 2D torus, 4 off-chip links at 500 Gbit/s; DMAs to other
  chips look like DMAs to local memory (easy for the compiler); scaling
  96-99% of linear on Google's applications.

## What changes for Imbewu (proposed; added to ROADMAP.md)

Confirmed by the reading (no change needed): inference first, not training;
cheap MX numerics in the engine with an FP32 vector unit beside it; a
programmable vector unit rather than fixed functions; scratchpad SRAM plus
data movers that feed the engine without the control core; everything
parameterised by grid size and tested small; memory bandwidth decides
whether more compute pays off.

New items:
1. Spare tiles and "disable a tile" (yield; Cerebras, and shipping GPUs).
2. Cost per *good* chip, with yield, in the cost model (G5).
3. Prefill and decode reported separately in the performance model;
   decode needs more queries per weight (batching, GQA, speculation).
4. Try a mixed cluster in simulation: one large grid for feed-forward,
   smaller grids for attention (design document).
5. Power: hot spots in the engine and a fast power limiter, not only a
   temperature sensor (TPUv3 experience).
6. An explicit "good enough" list next to G1-G5 (TPU paper).
7. Earlier FPGA demo of a real model generating text (OpenTPU shows a
   small team can do it on a low-cost board); timing closure on the FPGA
   is its own hurdle (Atik).
Not adopted: structured sparsity (the author now doubts it), wafer-scale,
very low memory (an option to study, not a plan).
