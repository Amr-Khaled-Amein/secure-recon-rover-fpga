r"""
puf_entropy.py : entropy and failure-rate calculation for the PUF key
generator (project brief §5.3). Prints the tables used in docs/puf_entropy.md.

Model
  - raw bit = one disjoint RO pair, after temporal majority voting
  - bias b = P(raw bit = 1); bits assumed independent (disjoint pairs)
  - pe = raw bit error rate after TMV (intra-chip, worst case over
    temperature/voltage; measured in Phase 4)
  - goal: remaining min-entropy >= 128 bits AND key failure <= 1e-6

Entropy accounting
  - Von Neumann (VN) debiasing: output bits unbiased; yield b(1-b) bits per
    raw bit; the mask (which pairs kept) is independent of the kept values.
  - code offset, unbiased input, linear [n,k] code: remaining = k per block.
  - code offset WITHOUT debiasing, repetition code (Koeberl et al. 2014):
    exact average min-entropy per block
        H = -log2( 1/2 * sum_w C(n,w) * max(b^w (1-b)^(n-w), b^(n-w) (1-b)^w) )
  - code offset WITHOUT debiasing, general [n,k] code: lower bound
        H >= k - n * (1 - H_inf(b)),  H_inf(b) = -log2(max(b, 1-b))

Run:  .venv\Scripts\python model\puf_entropy.py
"""
from math import comb, log2, ceil, sqrt

TARGET_BITS = 128
TARGET_FAIL = 1e-6
LUT_PER_RO = 3670 / 1280   # measured: puf_keygen minus aes128_core, Vivado 2026.1

# BCH codes (n, k, t), standard tables
BCH = [(127, 64, 10), (127, 57, 11), (127, 50, 13), (127, 43, 14), (127, 36, 15), (127, 29, 21),
       (255, 131, 18), (255, 123, 19), (255, 115, 21), (255, 107, 22), (255, 99, 23),
       (255, 91, 25), (255, 87, 26), (255, 79, 27), (255, 71, 29), (255, 63, 30),
       (255, 55, 31), (255, 47, 42), (255, 45, 43), (255, 37, 45)]


def binom_tail(n, p, t):
    """P(X > t), X ~ Bin(n, p)"""
    return sum(comb(n, i) * p**i * (1 - p)**(n - i) for i in range(t + 1, n + 1))


def rep_fail(R, pe):
    return binom_tail(R, pe, (R - 1) // 2)


def rep_block_entropy(R, b):
    q = 1 - b
    s = sum(comb(R, w) * max(b**w * q**(R - w), b**(R - w) * q**w) for w in range(R + 1))
    return -log2(0.5 * s)


def hinf(b):
    return -log2(max(b, 1 - b))


def raw_bits_for(debiased, b, debias):
    """raw bits needed so that, with 4-sigma margin, VN yields `debiased` bits"""
    if not debias:
        return debiased
    pairs_needed = debiased  # one kept pair -> one bit; P(keep) = 2b(1-b)
    pk = 2 * b * (1 - b)
    # smallest number of pairs m with m*pk - 4*sqrt(m*pk*(1-pk)) >= pairs_needed
    m = ceil(pairs_needed / pk)
    while m * pk - 4 * sqrt(m * pk * (1 - pk)) < pairs_needed:
        m += 1
    return 2 * m


def best_rep(b, pe, debias):
    for R in range(3, 41, 2):
        H = 1.0 if debias else rep_block_entropy(R, b)
        nb = ceil(TARGET_BITS / H)
        fail = 1 - (1 - rep_fail(R, pe)) ** nb
        if fail <= TARGET_FAIL:
            deb = nb * R
            return dict(code=f"rep({R})", blocks=nb, debiased=deb, raw=raw_bits_for(deb, b, debias),
                        fail=fail, H=nb * H)
    return None


def best_concat(b, pe, debias):
    """inner repetition (R1 = 1, 3, 5) + outer BCH; minimal raw bits"""
    best = None
    for R1 in (1, 3, 5):
        p1 = pe if R1 == 1 else rep_fail(R1, pe)
        for n, k, t in BCH:
            if debias:
                Hblk = k
            else:
                # bound: inner rep leaks too; treat the whole n*R1 block as one code
                Hblk = k - n * R1 * (1 - hinf(b)) if R1 == 1 else min(
                    k, n * rep_block_entropy(R1, b) - (n - k))
            if Hblk <= 0:
                continue
            B = ceil(TARGET_BITS / Hblk)
            fail = 1 - (1 - binom_tail(n, p1, t)) ** B
            if fail > TARGET_FAIL:
                continue
            deb = B * n * R1
            raw = raw_bits_for(deb, b, debias)
            cand = dict(code=f"rep({R1})+BCH({n},{k},{t})" if R1 > 1 else f"BCH({n},{k},{t})",
                        blocks=B, debiased=deb, raw=raw, fail=fail, H=B * Hblk)
            if best is None or raw < best["raw"]:
                best = cand
    return best


def row(b, pe, debias, c):
    if c is None:
        return f"| {b:.2f} | {100*pe:.0f}% | {'VN' if debias else 'none'} | no repetition code up to 39 works | | | | |"
    ros = 2 * c["raw"]
    return (f"| {b:.2f} | {100*pe:.0f}% | {'VN' if debias else 'none'} | {c['code']} x{c['blocks']} | "
            f"{c['H']:.0f} | {c['fail']:.1e} | {ros:,} | {ros*LUT_PER_RO:,.0f} |")


def main():
    print("Block min-entropy of a repetition code-offset without debiasing (bits per block):")
    print("| bias | rep(3) | rep(5) | rep(7) |")
    print("|---|---|---|---|")
    for b in (0.50, 0.55, 0.60, 0.70):
        print(f"| {b:.2f} | {rep_block_entropy(3, b):.3f} | {rep_block_entropy(5, b):.3f} | {rep_block_entropy(7, b):.3f} |")
    print()
    hdr = ("| bias | pe | debias | code | entropy (bits) | key failure | ROs | LUTs (ROs only) |\n"
           "|---|---|---|---|---|---|---|---|")
    print("Repetition code only (Phase 0 design):")
    print(hdr)
    for b in (0.50, 0.55):
        for pe in (0.01, 0.03, 0.05):
            for debias in (True, False):
                print(row(b, pe, debias, best_rep(b, pe, debias)))
    print()
    print("Concatenated repetition + BCH (final design, project brief §5.3):")
    print(hdr)
    for b in (0.50, 0.55):
        for pe in (0.01, 0.03, 0.05):
            for debias in (True, False):
                print(row(b, pe, debias, best_concat(b, pe, debias)))
    print()
    # the simulation configuration
    b, pe, R, NB, NRO = 0.467, 0.036, 5, 10, 640
    print(f"Simulation config (tb_puf_keygen): N_RO={NRO}, VN, rep({R}) x {NB}: "
          f"{NB} bits of entropy, block failure {rep_fail(R, pe):.1e} at pe={pe}")
    b, pe, R, NB = 0.5, 0.03, 5, 24
    print(f"RTL default (N_RO=1280, VN, rep(5) x 24): {NB} bits of entropy, "
          f"key failure {1-(1-rep_fail(R, pe))**NB:.1e} at pe=3%: pipeline demo only, NOT a 128-bit key")


if __name__ == "__main__":
    main()
