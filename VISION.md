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
