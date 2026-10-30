# TRNG (both boards)

`ro_trng` → `trng_health` → `session_kdf` (CBC-MAC conditioning) → 64-bit nonces.

## Source (`rtl/common/ro_trng.v`)

- 4 free-running ring oscillators, XORed together.
- Sampled by the 100 MHz clock through a 2-flop synchronizer.
- One raw bit every DECIM = 64 cycles (default; set from hardware measurements in Phase 4).

## Health tests (`rtl/common/trng_health.v`, NIST SP 800-90B §4.4)

False-alarm rate α = 2⁻²⁰. The cutoffs depend on the assumed min-entropy H per raw bit:

| H (bits/sample) | RCT cutoff = 1 + ⌈20/H⌉ | APT cutoff (W = 1024) |
|---|---|---|
| 1.0 | 21 | 589 |
| 0.8 | 26 | 664 |
| **0.5 (default)** | **41** | **793** |
| 0.4 | 51 | 840 |

APT cutoff = 1 + CRITBINOM(1024, 2⁻ᴴ, 1 − α), computed exactly in Python. The H = 1.0 value, 589, matches the table in SP 800-90B.

- **Start-up:** no output until the first 1,024-sample APT window passes.
- **On any failure:** output blocked and `fail` latched until reset. With no random bits, no nonce is produced, so no HELLO is sent (tested in `tb_hello_fsm`, test 8).
- **What these tests do not catch:** RCT and APT catch stuck outputs, long runs and strong bias. They do **not** catch a balanced periodic pattern such as 0101…. Offline statistical tests on captured data cover that (project brief §10.11, NIST SP 800-22 subset).

## Conditioning (`rtl/common/session_kdf.v`, OP_NONCE)

- AES CBC-MAC over 4 × 128 health-tested bits with the fixed public key `"rover-trng-cond0"`.
- The nonce is the upper 64 bits.
- With H = 0.5, the 512 raw bits carry 256 bits of entropy, at least 64 + 64 more than the 128-bit output (SP 800-90B full-entropy rule of thumb).

## Phase 4 to do

- Capture ≥ 1 Mbit of raw bits per board through a debug-only path. This is allowed for the TRNG, never for K.
- Estimate H with the SP 800-90B non-IID tools.
- Set DECIM and the cutoffs from the result.
