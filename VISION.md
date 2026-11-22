# Vision

## Mission

Become Africa's leading AI-chip designer and the go-to partner for every
African company, lab and government with AI ambitions.

## The goal

An AI accelerator architecture for **African data centres**, able to train and
run large AI models, including models built for African languages and data.

We don't need a manufactured chip to make the case. The first target is a
**pitch package that runs entirely in simulation**, the way chip startups
pitch before they have silicon:

1. **A documented architecture**: the full-scale chip, explained clearly.
2. **A verified compute tile**: the core building block, in real chip-design
   code, passing thorough automated tests.
3. **A multi-tile simulation**: proof that tiles work together as the design
   scales (4, then 16 tiles and more).
4. **A performance model**: software that projects how the full chip would
   perform on large language models, with an honest comparison to existing
   chips.

With that, plus a cost and team plan for reaching silicon, we approach
government (DSI, DTIC, IDC and similar), research partners and investors for
engineers and funding.

## The five design goals

Set by the founder. Every part of the architecture must serve at least one.

| # | Goal | What it means for the chip | How we prove it before silicon |
|---|------|---------------------------|--------------------------------|
| G1 | **Massive parallel computation** | Thousands of matrix engines working at once; flexible precision (FP8, FP4 and others) to multiply speed without losing accuracy | Verified engines and tiles in simulation; accuracy tests of each number format on real model data |
| G2 | **High-speed chip-to-chip communication** | Many chips act as one machine, with no chip waiting on its neighbours | Simulated on-chip network and chip-to-chip links; a model of thousands of chips training together |
| G3 | **Ultra-fast memory bandwidth** | Data reaches the engines continuously, with no "memory wall"; designed for stacked HBM | Memory-controller design plus a bandwidth model fed by real AI workloads |
| G4 | **Low-latency, high-throughput inference** | Fast answers for each user and many users at once, including reasoning models that "think" longer | Performance model of tokens per second, response time and users served |
| G5 | **Performance per watt** | The most AI output per megawatt, suited to costly, unreliable African power | Power estimates from the design tools, energy per operation, performance per watt and per rand |

### What a chip company designs vs. buys

Real chip companies, Nvidia included, don't build everything themselves:

- **Memory (G3):** HBM stacks are bought from SK hynix, Samsung or Micron.
  We design the memory controller and how data moves; the high-speed
  physical connection (the "PHY") is normally licensed.
- **Chip-to-chip links (G2):** NVLink is Nvidia's private technology. We
  build on open industry standards such as UALink and Ultra Ethernet. The
  high-speed transmitters (SerDes) are normally licensed.
- **Cooling (G5):** liquid cooling belongs to the server and the data centre,
  not the chip. Our part is keeping the chip's power low and even so it is
  easier and cheaper to cool.

Knowing this split is part of a credible pitch: it shows funders exactly
which parts are Imbewu's own invention and which are bought in.

## Why Africa needs this

- **Sovereignty.** Africa currently depends entirely on chips designed and
  controlled elsewhere. Supply can be restricted for political reasons.
  A continent that wants its own AI models and data centres needs some
  control over the hardware underneath them.
- **African AI models.** South Africa and the continent plan to build their
  own AI models, including models for African languages. Those need data
  centres, and data centres need AI chips.
- **African data-centre conditions.** Expensive and unreliable electricity
  and cooling, and tight budgets. A chip designed for these conditions is a
  different chip from one designed for American hyperscalers.
- **Energy efficiency as a design principle.** Every Imbewu design is judged
  on performance per watt and per rand, not only raw performance.

## Focus

Imbewu has one focus: the data-centre AI accelerator. We are not building
edge chips, plug-in inference cards or other side products along the way.
Every design, test and document in this repository serves the data-centre
chip and its pitch package (D-007).

## Roles

- **Anele (founder, visionary):** the problem we solve, who pays, money,
  partners, hiring, the pitch.
- **Claude (research, architecture, design, verification):** does the
  engineering, explains every decision in plain language, keeps this
  repository up to date.
- **Human chip engineers (later):** review the design before any money is
  spent on manufacturing.

## What simulation does and doesn't prove

Simulation proves the architecture works: the maths is right, the design
scales, and real AI models run on it. It doesn't prove the chip is ready to
manufacture. That needs experienced engineers, physical design on a modern
process, licensed interface blocks, a software stack and funding. We say
this plainly in every pitch (D-014), and the roadmap's workstreams (W1-W5)
show how each gap gets closed.
