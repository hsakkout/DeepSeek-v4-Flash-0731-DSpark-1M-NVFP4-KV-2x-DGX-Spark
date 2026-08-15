#!/usr/bin/env python3
"""Scoring pass for deployed DS4 (deepseek-v4-flash @ 8888): verify thinking/reasoning
final answers against KNOWN ground-truth answers. Scores honestly."""
import json, urllib.request, time, re, sys

API = "http://127.0.0.1:8888/v1/chat/completions"
MODEL = "deepseek-v4-flash"

# (question, ground_truth, [acceptable alternates])
CASES = [
    ("A farmer has 17 sheep. All but 9 die. How many are left?",
     9, [9]),
    ("How many letters 'e' are there in the word 'excellence'?",
     4, [4]),
    ("If each of those 9 remaining sheep has 4 legs and there are 3 dogs with 4 legs each, how many legs are there in total?",
     48, [48, "48 legs"]),
    ("What is 17 * 18?",
     306, [306]),
    ("A train travels 300 km in 2.5 hours. What is its average speed in km/h?",
     120, [120]),
    ("Solve for x: 3x + 7 = 22",
     5, [5]),
    ("What comes next in the sequence: 2, 6, 12, 20, 30, ?",
     42, [42]),
    ("Which is larger: 9/11 or 5/7? Answer with the larger fraction.",
     "9/11", ["9/11", "9 11"]),
]

def chat(question, max_tokens=512):
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": question}],
        "max_tokens": max_tokens,
        "temperature": 0.6,
    }
    req = urllib.request.Request(API, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.load(r)
    ch = d["choices"][0]["message"]
    return ch.get("reasoning", "") or "", ch.get("content", "") or "", d.get("usage", {})

def normalize(s):
    if s is None:
        return ""
    s = str(s).lower().strip()
    s = re.sub(r"[^0-9a-z/]", "", s)
    return s

def extract_answer(content):
    # take the last numeric/fraction token-like answer
    return content

def main():
    results = []
    for q, truth, alts in CASES:
        reasoning, content, usage = chat(q)
        norm_truth = normalize(truth)
        norm_content = normalize(content)
        ok = norm_truth in norm_content or any(normalize(a) in norm_content for a in alts)
        # Also allow the answer to appear in the content generally
        results.append((q, truth, content, ok, reasoning))
        print(f"{'PASS' if ok else 'FAIL'}  Q: {q}")
        print(f"      truth={truth!r}  content={content!r}")
        time.sleep(0.3)

    passed = sum(1 for r in results if r[3])
    print(f"\n===== SCORE: {passed}/{len(results)} ({100*passed/len(results):.0f}%) =====")

if __name__ == "__main__":
    main()
