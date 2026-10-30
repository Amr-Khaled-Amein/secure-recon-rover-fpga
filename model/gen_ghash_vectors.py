r"""
gen_ghash_vectors.py : vectors for tb_ghash.sv.

Output: model/vectors/ghash.txt, one test per line:
  h nblocks x_0 .. x_{n-1} y_0 .. y_{n-1}
where y_i is the accumulator after block i (Y_0 = 0, Y_i = (Y_{i-1} xor X_i) * H).
The GHASH model is first checked against the library: the GCM tag computed
with it must equal cryptography's AESGCM tag for 200 random messages.

Run:  .venv\Scripts\python model\gen_ghash_vectors.py
"""
import os
import random
import sys

import gcm_model as m

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")


def main():
    rng = random.Random(5)
    for _ in range(200):
        k, iv = rng.randbytes(16), rng.randbytes(12)
        a, p = rng.randbytes(rng.randint(0, 40)), rng.randbytes(rng.randint(0, 80))
        ct, tag = m.gcm_encrypt(k, iv, p, a)
        if m.gcm_tag_manual(k, iv, ct, a) != tag:
            sys.exit("GHASH model disagrees with the library")
    rows = []
    for t in range(30):
        h = rng.randbytes(16) if t > 1 else (bytes(16) if t == 0 else bytes([0x80]) + bytes(15))
        xs = [rng.randbytes(16) for _ in range(rng.randint(1, 6))]
        ys, y = [], b""
        for i in range(len(xs)):
            ys.append(m.ghash(h, xs[:i + 1]))
        rows.append(" ".join([h.hex(), str(len(xs))] + [x.hex() for x in xs] + [y.hex() for y in ys]) + "\n")
    with open(os.path.join(OUT, "ghash.txt"), "w", newline="\n") as f:
        f.writelines(rows)
    print("GHASH model matches the library on 200 GCM tags; ghash.txt: %d vectors" % len(rows))


if __name__ == "__main__":
    main()
