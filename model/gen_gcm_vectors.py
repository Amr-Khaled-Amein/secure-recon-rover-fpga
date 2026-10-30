"""
gen_gcm_vectors.py : write AES-GCM test vectors for tb_aes_gcm.sv.

Output (model/vectors/):
  gcm_kat.txt         McGrew-Viega test cases 1-4, checked against the library
  gcm_random.txt      random vectors (incl. the real packet shape 18 B AAD + 640 B)
  gcm_wycheproof.txt  Wycheproof AES-GCM, 128-bit key, 96-bit IV, 128-bit tag

One test per line, fields separated by spaces:
  id key(32 hex) iv(24 hex) aad_len pt_len aad pt ct tag(32 hex) valid
Empty byte strings are written as "00" (the length field says 0).
valid = 1: tag must match and the decrypted text must equal pt.
valid = 0: the tag must NOT match (pt is unused).

Run:  .venv\\Scripts\\python model\\gen_gcm_vectors.py  [seed]
"""
import json
import os
import random
import sys

from gcm_model import gcm_encrypt, gcm_decrypt

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")
MAX_LEN = 1024  # bytes; matches the testbench buffers

# McGrew & Viega, "The Galois/Counter Mode of Operation", Appendix B.
K3 = "feffe9928665731c6d6a8f9467308308"
IV3 = "cafebabefacedbaddecaf888"
P3 = ("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
      "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
C3 = ("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
      "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985")
KAT = [
    # name, key, iv, aad, pt, ct, tag
    ("tc1", "00" * 16, "00" * 12, "", "", "", "58e2fccefa7e3061367f1d57a4e7455a"),
    ("tc2", "00" * 16, "00" * 12, "", "00" * 16,
     "0388dace60b6a392f328c2b971b2fe78", "ab6e47d42cec13bdf53a67b21257bddf"),
    ("tc3", K3, IV3, "", P3, C3, "4d5c2af327cd64a62cf35abd2ba6fab4"),
    ("tc4", K3, IV3, "feedfacedeadbeeffeedfacedeadbeefabaddad2", P3[:120], C3[:120],
     "5bc94fbc3221a5db94fae95ae7121a47"),
]


def line(tid, key, iv, aad, pt, ct, tag, valid):
    h = lambda b: b.hex() if b else "00"
    return f"{tid} {key.hex()} {iv.hex()} {len(aad)} {len(pt)} {h(aad)} {h(pt)} {h(ct)} {tag.hex()} {int(valid)}\n"


def kat():
    rows = []
    for name, k, iv, a, p, c, t in KAT:
        k, iv, a, p, c, t = map(bytes.fromhex, (k, iv, a, p, c, t))
        ct, tag = gcm_encrypt(k, iv, p, a)
        if (ct, tag) != (c, t):
            sys.exit(f"{name}: published vector does not match the library")
        rows.append(line(name, k, iv, a, p, c, t, 1))
    return rows


def rand_vectors(rng, n):
    rows = []
    shapes = [(18, 640), (18, 0), (18, 16), (0, 0), (16, 16), (20, 60)]
    for i in range(n):
        if i < len(shapes):
            alen, plen = shapes[i]
        else:
            alen, plen = rng.randint(0, 48), rng.randint(0, 200)
        k = rng.randbytes(16)
        iv = rng.randbytes(12)
        a = rng.randbytes(alen)
        p = rng.randbytes(plen)
        ct, tag = gcm_encrypt(k, iv, p, a)
        rows.append(line(f"r{i}", k, iv, a, p, ct, tag, 1))
        # same vector with one flipped bit: must be rejected
        if i % 4 == 0:
            t2 = bytearray(tag)
            t2[rng.randrange(16)] ^= 1 << rng.randrange(8)
            rows.append(line(f"r{i}_badtag", k, iv, a, p, ct, bytes(t2), 0))
            if ct:
                c2 = bytearray(ct)
                c2[rng.randrange(len(c2))] ^= 1 << rng.randrange(8)
                rows.append(line(f"r{i}_badct", k, iv, a, p, bytes(c2), tag, 0))
            if a:
                a2 = bytearray(a)
                a2[rng.randrange(len(a2))] ^= 1 << rng.randrange(8)
                rows.append(line(f"r{i}_badaad", k, iv, bytes(a2), p, ct, tag, 0))
    return rows


def wycheproof():
    with open(os.path.join(OUT, "aes_gcm_test.json")) as f:
        data = json.load(f)
    rows, skipped = [], 0
    for g in data["testGroups"]:
        if g["keySize"] != 128 or g["ivSize"] != 96 or g["tagSize"] != 128:
            skipped += len(g["tests"])
            continue
        for t in g["tests"]:
            k, iv, a, p, c, tag = (bytes.fromhex(t[x]) for x in ("key", "iv", "aad", "msg", "ct", "tag"))
            if max(len(a), len(p)) > MAX_LEN:
                skipped += 1
                continue
            valid = t["result"] == "valid"
            # the library must agree with Wycheproof on every vector we use
            got = gcm_decrypt(k, iv, c, a, tag)
            if valid != (got is not None) or (valid and got != p):
                sys.exit(f"wycheproof tcId {t['tcId']}: library disagrees")
            rows.append(line(f"w{t['tcId']}", k, iv, a, p, c, tag, valid))
    return rows, skipped


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 2026
    rng = random.Random(seed)
    os.makedirs(OUT, exist_ok=True)
    w, skipped = wycheproof()
    for name, rows in (("gcm_kat.txt", kat()),
                       ("gcm_random.txt", rand_vectors(rng, 200)),
                       ("gcm_wycheproof.txt", w)):
        with open(os.path.join(OUT, name), "w", newline="\n") as f:
            f.writelines(rows)
        print(f"{name}: {len(rows)} vectors")
    print(f"wycheproof: {skipped} vectors skipped (other key/IV/tag sizes)")


if __name__ == "__main__":
    main()
