#!/usr/bin/env python3
"""Real attention scores on the simulated tile (decision D-021).

Captures Q and K from inside a real model's attention (after the rotary
position code), for one layer and one head, and computes the scores
Q x K^T on the simulated tile three ways: plain MX INT8, plain MX FP8, and
with K carried in 14 bits by splitting it into two INT8 blocks.

Usage: python3 tools/real_scores_on_tile.py [MODEL] [LAYER] [HEAD] [TOKENS]
"""
import json
import os
import sys

import torch

sys.path.insert(0, os.path.dirname(__file__))
from imbewu_compile import ROOT, imbewu_attention_scores, imbewu_linear   # noqa: E402


def capture(model_id, layer, head, tokens):
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.models.qwen2 import modeling_qwen2 as m
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch.float32,
                                                 attn_implementation="eager").eval()
    text = [t for t in load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1",
                                    split="test")["text"] if len(t) > 200][0]
    ids = tok(text, return_tensors="pt").input_ids[:, :tokens]
    got, orig = {}, m.eager_attention_forward

    def spy(module, query, key, value, *a, **kw):          # record, then run as normal
        if module.layer_idx == layer and "q" not in got:
            g = module.num_key_value_groups
            got["q"], got["k"] = query[0, head].detach(), key[0, head // g].detach()
        return orig(module, query, key, value, *a, **kw)
    m.eager_attention_forward = spy
    with torch.no_grad():
        model(ids)
    m.eager_attention_forward = orig
    return got["q"], got["k"]


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else "Qwen/Qwen2.5-0.5B"
    layer = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    head = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    tokens = int(sys.argv[4]) if len(sys.argv) > 4 else 32
    q, k = capture(model_id, layer, head, tokens)
    ref = q.double() @ k.double().t()
    scale = q.shape[1] ** -0.5
    mask = torch.triu(torch.full((tokens, tokens), float("-inf"), dtype=torch.float64), 1)
    p_ref = torch.softmax(ref * scale + mask, -1)

    def prob_error(y):
        """How far the attention weights (after softmax) move: largest change
        of any weight, and the average total change per token (0 to 2)."""
        p = torch.softmax(y.double() * scale + mask, -1)
        return dict(max_weight_change=round(float((p - p_ref).abs().max()), 5),
                    mean_total_change_per_token=round(float((p - p_ref).abs().sum(-1).mean()), 5))
    out = dict(model=model_id, layer=layer, head=head, tokens=tokens, head_dim=int(q.shape[1]), runs=[])
    for name in ("mxint8", "mxfp8"):
        lin = torch.nn.Linear(k.shape[1], k.shape[0], bias=False)
        lin.weight.data = k.float()
        y, r = imbewu_linear(lin, q.float(), name, name, N=16, packed=False,
                             work=os.path.join(ROOT, "build", "compile", f"real_scores_{name}"))
        r["scores_as"] = f"plain {name}"
        r["attention_weights"] = prob_error(y)
        out["runs"].append(r)
        print(json.dumps({x: r[x] for x in ("scores_as", "bit_exact_vs_reference",
                                            "relative_error_vs_pytorch_fp32_pct", "attention_weights")}), flush=True)
    y, r = imbewu_attention_scores(q, k, N=16, work=os.path.join(ROOT, "build", "compile", "real_scores_split"))
    r["scores_as"] = "K split into two INT8 blocks (14-bit K)"
    r["attention_weights"] = prob_error(y)
    out["runs"].append(r)
    print(json.dumps({x: r[x] for x in ("scores_as", "bit_exact_vs_reference", "bit_exact_vs_fast_model",
                                        "relative_error_vs_pytorch_fp32_pct", "attention_weights",
                                        "tile_timing")}), flush=True)
    with open(os.path.join(ROOT, "results", f"real_scores_qwen0.5b_l{layer}_h{head}.json"), "w") as fh:
        json.dump(out, fh, indent=2)


if __name__ == "__main__":
    main()
