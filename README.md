# Imbewu

*Imbewu* means "seed" in isiXhosa. This repository is the engineering workshop
for an African AI-chip venture. The long-term goal is an AI accelerator for
African data centres, so that African AI models can be trained and run on
hardware designed in Africa.

Start here:

| File | What it holds |
|------|---------------|
| [VISION.md](VISION.md) | What we're building and why |
| [ROADMAP.md](ROADMAP.md) | The phases and where we are now |
| [DECISIONS.md](DECISIONS.md) | Every major decision and the reason for it |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The pitch-ready architecture document (link) and what it covers |
| [docs/RESULTS.md](docs/RESULTS.md) | Measured test and size results |
| [docs/LEARNING.md](docs/LEARNING.md) | Plain-language explanations of the chip concepts used here |

## Layout

```
rtl/     chip designs, written in Verilog
tests/   automated tests (testbenches) for each design
formal/  formal (mathematical) proofs of the designs' rules
tools/   Python helpers, e.g. independent reference models for tests
docs/    explanations and architecture documents
```

## Running the tests (free, no hardware needed)

Requires Icarus Verilog and Yosys (both free and open source).
On Ubuntu: `sudo apt-get install iverilog yosys`.
Python packages for the reference models: `pip install -r tools/requirements.txt`.

```bash
make test    # simulate every design and check every answer
make formal  # prove the engine's output rules for every possible input
make mutants # plant bugs on purpose and check the tests catch them
make synth   # convert designs to logic gates and report their size
```

## Policy

Every design here is our own work, built only from public, legitimately
available sources (papers, patents, conference talks, open-source designs
under their licences). See DECISIONS.md, D-003.
