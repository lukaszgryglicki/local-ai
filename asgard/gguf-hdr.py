#!/usr/bin/env python3
"""Header-only GGUF tensor inventory (works on partial .part files). Usage: gguf_hdr.py FILE [FILE...]"""
import struct, sys, re, collections
for _d in ('/data/ai/local-agent-poc/src/llama.cpp-master/gguf-py', '/data/ai/local-agent-poc/src/llama.cpp/gguf-py'):
    sys.path.insert(0, _d)
from gguf.constants import GGML_QUANT_SIZES, GGMLQuantizationType
class R:
    def __init__(s, f): s.f = f
    def u32(s): return struct.unpack('<I', s.f.read(4))[0]
    def u64(s): return struct.unpack('<Q', s.f.read(8))[0]
    def s(s): n = s.u64(); return s.f.read(n).decode('utf-8', 'replace')
    def val(s, t):
        sz = {0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
        if t in sz: return struct.unpack('<'+sz[t], s.f.read(struct.calcsize(sz[t])))[0]
        if t == 8: return s.s()
        if t == 9:
            et = s.u32(); n = s.u64(); return [s.val(et) for _ in range(n)]
        raise ValueError(t)
def inv(path):
    with open(path, 'rb') as f:
        r = R(f); assert f.read(4) == b'GGUF'; ver = r.u32(); nt = r.u64(); nkv = r.u64()
        kv = {}
        for _ in range(nkv):
            k = r.s(); t = r.u32(); v = r.val(t)
            kv[k] = v
        tens = []
        for _ in range(nt):
            name = r.s(); nd = r.u32(); dims = [r.u64() for _ in range(nd)]; ty = r.u32(); off = r.u64()
            bs, ts = GGML_QUANT_SIZES[GGMLQuantizationType(ty)]
            n = 1
            for d in dims: n *= d
            tens.append((name, dims, GGMLQuantizationType(ty).name, n * ts // bs))
    return kv, tens
tot = collections.Counter(); cnt = collections.Counter(); allt = []
for p in sys.argv[1:]:
    kv, tens = inv(p)
    print(f"# {p.split('/')[-1]}: {len(tens)} tensors, split {kv.get('split.no')}/{kv.get('split.count')} tensors_count={kv.get('split.tensors.count')}")
    for name, dims, ty, nb in tens:
        allt.append((name, dims, ty, nb))
        g = re.sub(r'blk\.\d+\.', 'blk.N.', name)
        tot[g] += nb; cnt[g] += 1
print(f"{'group':48s} {'n':>4s} {'GiB':>8s} types")
types = collections.defaultdict(set)
for name, dims, ty, nb in allt: types[re.sub(r'blk\.\d+\.', 'blk.N.', name)].add(ty)
for g, nb in sorted(tot.items(), key=lambda x: -x[1]):
    print(f"{g:48s} {cnt[g]:4d} {nb/2**30:8.2f} {','.join(sorted(types[g]))}")
print(f"TOTAL {sum(tot.values())/2**30:.2f} GiB in {len(allt)} tensors")
exps = sum(v for k, v in tot.items() if '_exps' in k)
print(f"experts (ffn_*_exps): {exps/2**30:.2f} GiB; everything else: {(sum(tot.values())-exps)/2**30:.2f} GiB")
