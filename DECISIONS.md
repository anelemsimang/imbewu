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
