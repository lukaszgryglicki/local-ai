#!/usr/bin/env python3
# /data/local-ai/asgard/e2e-vectors.py N [OUT] - deterministic base64 acceptance vectors for the ASM E2E task:
# N lines "<hex input>\t<expected base64>" (seeded, so verify-asm.sh can regenerate the same set and never has to
# trust the VECTORS.txt the model had write access to). Sizes: 0..80 bytes systematically first (covers every
# padding case), then random 1..48-byte inputs, every 50th line a 200-byte one. Prints to OUT or stdout.
import base64, random, sys
n = int(sys.argv[1]); out = open(sys.argv[2], "w") if len(sys.argv) > 2 else sys.stdout
rng = random.Random(20260911)
for i in range(n):
    if i <= 80: size = i
    elif i % 50 == 0: size = 200
    else: size = rng.randint(1, 48)
    data = rng.randbytes(size)
    out.write("%s\t%s\n" % (data.hex(), base64.b64encode(data).decode()))
