# Utilization (real Vivado numbers)

- **Device:** `xc7a35tcpg236-1` (20,800 LUTs, 41,600 FFs, 50 BRAM36, 90 DSP).
- **Method:** each core is synthesized, placed and routed out-of-context with a 100 MHz clock (`scripts\synth.tcl`; all at once with `scripts\run_all.bat`).
- **Tool and date:** Vivado 2026.1, 2026-10-27.

| Module | LUTs | FFs | BRAM36 | DSP | WNS @100 MHz | Est. Fmax | Budget (project brief §7) |
|---|---|---|---|---|---|---|---|
| aes128_core (incl. 20× aes_sbox) | 1,284 (6.2%) | 286 | 0 | 0 | +3.385 ns | ~151 MHz | 1,500–2,500 LUTs ✔ |
| ghash (bit-serial) | 269 | 521 | 0 | 0 | +4.057 ns | ~168 MHz | 400–600 LUTs ✔ |
| aes_gcm (AES + GHASH + control, incl. ECB mode) | 2,363 (11.4%) | 2,052 | 0 | 0 | +1.498 ns | ~118 MHz | AES + GHASH: 1,900–3,100 ✔ |
| motion_detect (320×240 frame buffer) | 192 | 132 | 19 | 0 | +3.006 ns | ~143 MHz | 200–300 LUTs, ~19 BRAM ✔ |
| puf_keygen (1,280 ROs + debias + rep code + own AES for the hash) | 5,083 (24.4%) | 903 | 0 | 0 | +3.188 ns | ~147 MHz | 4,000–6,500 ✔ (see note 3) |
| ro_trng (4 ROs) | 13 | 10 | 0 | 0 | +6.804 ns | ~313 MHz | TRNG + health + KDF + HELLO: 200–400 |
| trng_health (RCT + APT) | 43 | 38 | 0 | 0 | +4.971 ns | ~199 MHz | (same line) |
| session_kdf (excl. the shared aes_gcm) | 762 | 1,158 | 0 | 0 | +3.454 ns | ~153 MHz | (same line) ✘ |
| hello_fsm | 981 | 1,829 | 0 | 0 | +2.269 ns | ~129 MHz | (same line) ✘ |

## Notes

1. **S-boxes in LUTs:** they are forced into LUTs (`rom_style = "distributed"` in `aes_sbox`). Left to itself, Vivado puts them in 11 RAMB18 (~6 BRAM36) that the frame buffers need.
2. **Frame buffer in banks:** `motion_detect` uses 19 banks of 4K×8, one BRAM36 each. A single 76,800-deep array made Vivado cascade 32K×1 blocks: 24 BRAM36 and a 78 MHz timing failure.
3. **PUF:**
   - Each RO cell is 3 LUTs with its own hierarchy (`DONT_TOUCH`), so all 1,280 cells are identical. Without that, Vivado merged the pair-select logic into each cell.
   - `puf_keygen` includes its own `aes128_core` (1,284 LUTs) for the hash. In `rover_top` it can share the GCM core, giving about 3,800 LUTs.
   - These are the Phase 0 parameters. The final size depends on the PUF decision in `docs/puf_entropy.md`.
4. **Session block over budget:** `session_kdf` + `hello_fsm` = 1,743 LUTs against the 200–400 budget. Most of it is wide registers: the 384-bit AAD and several 128-bit keys/tags held twice, once in each module. Fixes for Phase 3:
   - build the AAD on the fly instead of registering it
   - pass the 128-bit operands by reference (one shared register file)
   - drop `cur_ks` / `pend_ks` duplication by keeping the keys in a small LUTRAM
5. **Timing:** every core meets 100 MHz. `aes_gcm` has the smallest margin (+1.5 ns, the GHASH-input mux). Watch it in the full top level.

## Rough rover total (Phase 0 cores)

| | LUTs | BRAM36 |
|---|---|---|
| aes_gcm (shared by video, commands, KDF and PUF hash) | 2,363 | 0 |
| PUF without its own AES | ~3,800 | 0 |
| TRNG + health + session (before the fixes in note 4) | ~1,800 | 0 |
| motion_detect | 192 | 19 |
| **Subtotal** | **~8,150 (39%)** | **19** |

Still to come: camera, SPI, packetizer, TX buffer (SRAM controller), PWM. The project brief (§7) estimates them at about 1,000–1,600 LUTs and 3 BRAM36.
