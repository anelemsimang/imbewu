# Decision log

Every major decision, with the reason. Newest at the bottom.

### D-001 - Open-source foundations, starting from the ET-SoC-1 family of ideas
The strongest open-source AI chip is the Esperanto ET-SoC-1 (1,024 RISC-V
cores, ~40 W), released under Apache 2.0 by Ainekko's AI Foundry. We study it
and other open designs (Vortex, XiangShan) as public references.

### D-002 - Stage 4 (data-centre AI chip) is the primary focus
Founder's decision. South Africa's ambition to build its own AI models makes
a data-centre design the strongest case for government backing. We design and
prove it in simulation first; manufacturing comes with funding and engineers.

### D-003 - Clean design: public and legitimate sources only
No leaked or confidential designs or documents, even for study. A design
shaped by someone else's trade secrets is legally contaminated, which would
fail investor and government due diligence and invite lawsuits. We use papers,
patents, conference talks, teardown analyses and open-source designs under
their licences. This record of clean origin is itself an asset in the pitch.

### D-004 - Free, open-source tools for all simulation and testing
Icarus Verilog for simulation, Yosys for converting designs into gates, and
later OpenROAD/OpenLane with open process kits (SkyWater 130 nm, GF180) for
layout. Cost: R0.

### D-005 - Continuity through this repository
Claude's memory between chats is limited. This repository is the permanent
record. Each work session starts by reading ROADMAP.md and DECISIONS.md and
ends by updating them.

### D-006 - Systolic array for the compute core
The matrix-multiply engine is a systolic array: a grid of simple cells that
pass numbers to their neighbours. It's a well-published, proven approach
(Kung & Leiserson 1978; Google's TPU papers), uses little power because data
is reused instead of fetched repeatedly from memory, and scales by making the
grid larger. First version: 4x4, INT8 inputs, INT32 results.

### D-007 - Sole focus on the data-centre chip (Stage 4)
Founder's decision. Stages 1-3 (edge chips, inference cards, model-support
products) are removed from the plan. All work goes to the data-centre AI
accelerator and its simulation-based pitch package. Replaces the "ladder"
in earlier versions of VISION.md.

### D-008 - Five design goals
Founder's definition of what the data-centre chip must achieve: massive
parallel computation with flexible precision (G1), high-speed chip-to-chip
communication (G2), ultra-fast memory bandwidth (G3), low-latency,
high-throughput inference (G4) and performance per watt (G5). Each roadmap
item is tagged with the goals it serves.

### D-009 - Open standards for precision and chip-to-chip links
Low-precision formats follow the open OCP Microscaling (MX) specification
(MXFP8, MXFP4 and others) rather than a private format. Chip-to-chip links
build on open industry standards (UALink, Ultra Ethernet) rather than
copying NVLink. Both keep the design clean (D-003) and compatible with
the wider industry.

### D-010 - Streaming engine with tagged data
Version 2 of the matrix engine tags each number with "valid" and "last"
instead of using a central controller to start and stop jobs. Jobs run back
to back, utilisation rises from ~33% to 99.5%, and the shared dimension K
can vary per job. Cost: ~7% more logic. Version 1 (`rtl/systolic_array.v`)
stays in the repository as the simple reference design.

### D-011 - Multi-format engine with exact fixed-point accumulation
Version 3 supports INT8, FP8 E4M3 and FP4 E2M1 (OCP MX v1.0) in one cell,
selected per job by a tag that travels with the data. Products are summed
exactly in a 48-bit fixed-point total (smallest step 2^-18) instead of a
rounding floating-point adder: simpler, exactly verifiable, no rounding error
within a block. MX block scales are applied on the way out as an exponent.
Cost: the cell is 2.2x the INT8-only cell; reduction plans are in
docs/RESULTS.md. FP4 packs two numbers per lane for 2x speed.

### D-012 - Independent Python reference model for verification
Expected answers for the multi-format engine come from tools/gen_mx_vectors.py,
which decodes numbers with the public ml_dtypes library, not with logic copied
from the design, so a shared mistake in design and test is unlikely.

### D-013 - Workstreams answering the limits of an AI-led design team
An external review (another AI tool, shared by the founder) listed six
limits of a founder-plus-AI team: specification, complexity, verification,
physical design, software stack and industry gatekeepers. All six are real;
none blocks the simulation-based pitch, and our plan already requires human
engineers before money is spent on manufacturing. In response the roadmap
adds five workstreams: W1 verification depth (formal proofs, coverage,
lint), W2 real physical numbers (open layout flow), W3 software stack
(PyTorch to Imbewu), W4 an early performance model, W5 people and partners
(external review, advisor, design house, export-control advice). The
software stack was the largest gap in the earlier plan.

### D-014 - Honest scope statement in all pitch material
Every pitch document states plainly that simulation proves the architecture
works, not that the chip is ready to manufacture, and names what is needed
to get there (engineers, licensed blocks, a design house, funding).

### D-015 - INT8/FP8 are the main inference formats; add a mixed FP4 x FP8 mode
The accuracy check (docs/RESULTS.md, 2026-11-22) showed MXINT8 and MXFP8
lose under 4% on three public models, while plain MXFP4 for both weights and
activations loses 51-140%. FP4 weights with FP8 activations loses 14-45%.
So: INT8 and FP8 are the default inference formats; FP4 is offered for
weights, paired with FP8 activations. The engine will gain a mode where the
two inputs of a job use different formats. FP4 accuracy techniques (smaller
blocks, rotations) will be evaluated in software before adding hardware.
