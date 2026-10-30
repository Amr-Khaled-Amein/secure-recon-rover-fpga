"""
gen_puf_vectors.py : Davies-Meyer hash vectors for tb_puf_hash.sv.

Output: model/vectors/puf_hash_<NBITS>.txt, one vector per line:
  <input bits as hex, NBITS bits right-aligned> <K, 32 hex>
Bits are packed MSB-first into 128-bit blocks, last block zero-padded,
H0 = 0, H_i = AES_{m_i}(H_{i-1}) xor H_{i-1}  (gcm_model.davies_meyer).

Run:  .venv\\Scripts\\python model\\gen_puf_vectors.py
"""
import os
import random

from gcm_model import davies_meyer

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")


def puf_hash(bits):
    n = len(bits)
    nblk = (n + 127) // 128
    v = int("".join(map(str, bits)), 2) << (nblk * 128 - n)   # MSB-first, zero pad
    raw = v.to_bytes(nblk * 16, "big")
    return davies_meyer([raw[16 * i:16 * i + 16] for i in range(nblk)])


def main():
    rng = random.Random(7)
    os.makedirs(OUT, exist_ok=True)
    for nbits in (680, 128, 50):
        rows = []
        cases = [[0] * nbits, [1] * nbits] + [[rng.getrandbits(1) for _ in range(nbits)] for _ in range(18)]
        for bits in cases:
            hexw = (nbits + 3) // 4
            v = int("".join(map(str, bits)), 2)
            rows.append(f"{v:0{hexw}x} {puf_hash(bits).hex()}\n")
        name = f"puf_hash_{nbits}.txt"
        with open(os.path.join(OUT, name), "w", newline="\n") as f:
            f.writelines(rows)
        print(f"{name}: {len(rows)} vectors")


if __name__ == "__main__":
    main()
