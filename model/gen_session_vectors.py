r"""
gen_session_vectors.py : vectors for tb_session_kdf.sv.

Output (model/vectors/):
  kdf.txt    k nr nb ks                          K_s = AES_K(nr || nb)
  gmac.txt   key iv aad_len aad(96 hex, padded) tag valid
             (includes the exact rover / base HELLO layouts; valid = 0
              rows carry a corrupted tag)
  cond.txt   raw(512 bits = 4 blocks, 128 hex) X  (CBC-MAC conditioning)

Run:  .venv\Scripts\python model\gen_session_vectors.py
"""
import os
import random

import gcm_model as m

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors")


def main():
    rng = random.Random(11)
    os.makedirs(OUT, exist_ok=True)

    with open(os.path.join(OUT, "kdf.txt"), "w", newline="\n") as f:
        for _ in range(20):
            k, nr, nb = rng.randbytes(16), rng.randbytes(8), rng.randbytes(8)
            f.write(f"{k.hex()} {nr.hex()} {nb.hex()} {m.session_key(k, nr, nb).hex()}\n")

    rows = []
    for i in range(40):
        k, nr, nb = rng.randbytes(16), rng.randbytes(8), rng.randbytes(8)
        if i % 4 == 0:
            hdr, tag = m.hello_rover(k, nr)
            iv, aad = m.hello_iv(m.HELLO_ROVER, nr), hdr + nr
        elif i % 4 == 1:
            hdr, tag = m.hello_base(k, nr, nb)
            iv, aad = m.hello_iv(m.HELLO_BASE, nb), hdr + nr + nb
        else:
            iv, aad = rng.randbytes(12), rng.randbytes(rng.randint(1, 48))
            _, tag = m.gcm_encrypt(k, iv, b"", aad)
        rows.append((k, iv, aad, tag, 1))
        if i % 3 == 0:
            t2 = bytearray(tag)
            t2[rng.randrange(16)] ^= 1 << rng.randrange(8)
            rows.append((k, iv, aad, bytes(t2), 0))
    with open(os.path.join(OUT, "gmac.txt"), "w", newline="\n") as f:
        for k, iv, aad, tag, ok in rows:
            f.write(f"{k.hex()} {iv.hex()} {len(aad)} {(aad + bytes(48 - len(aad))).hex()} {tag.hex()} {ok}\n")

    with open(os.path.join(OUT, "cond.txt"), "w", newline="\n") as f:
        for _ in range(10):
            raw = rng.randbytes(64)
            f.write(f"{raw.hex()} {m.condition(raw).hex()}\n")
    print("kdf.txt: 20, gmac.txt: %d, cond.txt: 10 vectors" % len(rows))


if __name__ == "__main__":
    main()
