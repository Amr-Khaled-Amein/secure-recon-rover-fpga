# PUF entropy and sizing (project brief §5.3)

All numbers in this document come from `model/puf_entropy.py`. Rerun it after Phase 4 with the measured bias and error rate:

```
.venv\Scripts\python model\puf_entropy.py
```

## 1. Pipeline

`ro_puf` (disjoint RO pairs, temporal majority vote of 5) → `puf_debias` (Von Neumann, switchable) → `fuzzy_extractor` (code offset) → `puf_hash` (Davies–Meyer AES) → K

- **Raw bit:** one disjoint pair of ROs, so N_RO/2 bits. Neighbour-chain bits are not used because they are correlated.
- **Bias b** = P(raw bit = 1).
- **Error rate pe** = raw-bit error rate after majority voting, worst case over temperature and voltage.
- **Goal:** remaining min-entropy ≥ 128 bits, and key failure ≤ 10⁻⁶ per power-up.

## 2. Entropy accounting

| Step | Entropy effect |
|---|---|
| VN debiasing | Kept bits are unbiased if the raw bits are independent. Yield: b(1−b) bits per raw bit (0.25 at b = 0.5). The mask reveals only *which* pairs differed, not their values. |
| Code offset, unbiased input, [n,k] code | Helper data leaks n−k bits per block; k bits remain. |
| Code offset, **biased** input, repetition code | Exact average min-entropy per block (Koeberl et al. 2014, "the repetition code pitfall"): H = −log₂(½ Σ_w C(n,w) · max(bʷ(1−b)ⁿ⁻ʷ, bⁿ⁻ʷ(1−b)ʷ)) |
| Code offset, biased input, other codes | Lower bound H ≥ k − n·(1 − H∞(b)), with H∞(b) = −log₂ max(b, 1−b) |
| Davies–Meyer hash | Compresses the corrected bits to 128 bits; it cannot add entropy |

Min-entropy per repetition block without debiasing (bits):

| bias | rep(3) | rep(5) | rep(7) |
|---|---|---|---|
| 0.50 | 1.000 | 1.000 | 1.000 |
| 0.55 | 0.799 | 0.754 | 0.717 |
| 0.60 | 0.626 | 0.551 | 0.494 |
| 0.70 | 0.351 | 0.257 | 0.194 |

The "pitfall" grows quickly with bias: at b = 0.6, a rep(5) block keeps only 0.55 bits instead of 1.

## 3. Repetition code only (Phase 0 design)

Smallest repetition length that reaches 128 bits and a failure rate ≤ 10⁻⁶. LUTs are for the ROs only, at the measured 2.9 LUTs/RO.

| bias | pe | debias | code | entropy (bits) | key failure | ROs | LUTs (ROs only) |
|---|---|---|---|---|---|---|---|
| 0.50 | 1% | VN | rep(11) x128 | 128 | 5.7e-08 | 12,148 | 34,831 |
| 0.50 | 1% | none | rep(11) x128 | 128 | 5.7e-08 | 2,816 | 8,074 |
| 0.50 | 3% | VN | rep(15) x128 | 128 | 4.5e-07 | 16,384 | 46,976 |
| 0.50 | 3% | none | rep(15) x128 | 128 | 4.5e-07 | 3,840 | 11,010 |
| 0.50 | 5% | VN | rep(19) x128 | 128 | 7.6e-07 | 20,608 | 59,087 |
| 0.50 | 5% | none | rep(19) x128 | 128 | 7.6e-07 | 4,864 | 13,946 |
| 0.55 | 1% | VN | rep(11) x128 | 128 | 5.7e-08 | 12,276 | 35,198 |
| 0.55 | 1% | none | rep(11) x195 | 129 | 8.6e-08 | 4,290 | 12,300 |
| 0.55 | 3% | VN | rep(15) x128 | 128 | 4.5e-07 | 16,556 | 47,469 |
| 0.55 | 3% | none | rep(15) x209 | 128 | 7.3e-07 | 6,270 | 17,977 |
| 0.55 | 5% | VN | rep(19) x128 | 128 | 7.6e-07 | 20,820 | 59,695 |
| 0.55 | 5% | none | rep(21) x230 | 128 | 2.5e-07 | 9,660 | 27,697 |

**Result:** with the repetition code alone, a 128-bit key does not fit in the XC7A35T (20,800 LUTs) next to the rest of the rover, with or without debiasing.

## 4. Concatenated repetition + BCH (final design)

Best code per row (inner rep(1/3/5) + outer BCH from the standard n = 127/255 tables), chosen for the fewest ROs.

| bias | pe | debias | code | entropy (bits) | key failure | ROs | LUTs (ROs only) |
|---|---|---|---|---|---|---|---|
| 0.50 | 1% | VN | BCH(127,64,10) x2 | 128 | 1.5e-07 | 2,428 | 6,962 |
| 0.50 | 1% | none | BCH(127,64,10) x2 | 128 | 1.5e-07 | 508 | 1,457 |
| 0.50 | 3% | VN | BCH(255,91,25) x2 | 182 | 1.6e-07 | 4,624 | 13,258 |
| 0.50 | 3% | none | BCH(255,91,25) x2 | 182 | 1.6e-07 | 1,020 | 2,925 |
| 0.50 | 5% | VN | rep(3)+BCH(127,64,10) x2 | 128 | 6.0e-09 | 6,756 | 19,371 |
| 0.50 | 5% | none | rep(3)+BCH(127,64,10) x2 | 128 | 6.0e-09 | 1,524 | 4,370 |
| 0.55 | 1% | VN | BCH(127,64,10) x2 | 128 | 1.5e-07 | 2,456 | 7,042 |
| 0.55 | 1% | none | BCH(127,64,10) x3 | 140 | 2.3e-07 | 762 | 2,185 |
| 0.55 | 3% | VN | BCH(255,91,25) x2 | 182 | 1.6e-07 | 4,676 | 13,407 |
| 0.55 | 3% | none | BCH(255,91,25) x3 | 168 | 2.4e-07 | 1,530 | 4,387 |
| 0.55 | 5% | VN | rep(3)+BCH(127,64,10) x2 | 128 | 6.0e-09 | 6,828 | 19,577 |
| 0.55 | 5% | none | rep(3)+BCH(127,64,10) x4 | 154 | 1.2e-08 | 3,048 | 8,739 |

## 5. Conclusions and decision needed

1. **VN debiasing costs about 4.5× more ROs.** With VN, even the BCH designs need 2,400–6,800 ROs (7,000–19,600 LUTs). That is too large for this FPGA.
2. **Without VN, with the bias accounted for in the entropy,** BCH designs need 500–1,500 ROs (1,500–4,400 LUTs). This matches the ~1,280 ROs budgeted in project brief §7.
3. **Recommended path:**
   - Phase 4: measure b and pe on both boards (≥ 20 power cycles, hot and cold).
   - If b is within 0.45–0.55, deploy with `DEBIAS = 0` and the bias-aware entropy from §2. Keep VN (`DEBIAS = 1`) if the bias is larger.
   - Add the BCH outer decoder to `fuzzy_extractor`.
   - This deviates from project brief §5.3 ("add a debiasing step"): it replaces debiasing with exact bias accounting. **It needs the supervisor's agreement**; the thesis should show both tables.
4. **More bits per RO, if needed:** dark-bit masking (enrollment marks pairs with a small count difference as unreliable and skips them) lowers pe sharply. Masking or configurable ROs (Maiti & Schaumont) also help.

## 6. What the current RTL does

| Configuration | N_RO | Debias | Code | Entropy | Status |
|---|---|---|---|---|---|
| `tb_puf_keygen` (simulation) | 640 | VN | rep(5) x 10 | 10 bits | Pipeline test: enrollment, 6 power-ups give the same K; other chip gives a different K; biased chip stable |
| `puf_keygen` defaults (synthesis) | 1,280 | VN | rep(5) x 24 | 24 bits | Pipeline demo on hardware. **Not a 128-bit key.** |

Measured in simulation (behavioral RO model, σ = 1% process variation, 0.15% per-measurement noise): raw intra-chip HD 3.6% after majority voting, inter-chip HD 49.5%, and 0% after correction. These figures validate the RTL only. The real values come from Phase 4.

## 7. Known limitations (thesis)

- **Independence:** the analysis assumes disjoint RO pairs are independent. Spatial correlation (systematic gradients) reduces the entropy. Check it in Phase 4 with inter-chip HD and autocorrelation.
- **Helper data is unauthenticated:** manipulation attacks are possible (Delvaux & Verbauwhede). This is out of scope (project brief §2).
- **The PUF depends on bitstream protection** (project brief §5.5).
