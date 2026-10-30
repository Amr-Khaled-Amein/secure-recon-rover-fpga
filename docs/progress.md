# Progress

## Phase 0, step 1: aes128_core (2026-10-27): PASSED

Files
- `rtl/common/aes128_core.v`: iterative AES-128 encrypt, 1 round/clock, on-the-fly key expansion, start/done
- `rtl/common/aes_sbox.v`: S-box lookup table, kept in LUTs
- `tb/tb_aes128_core.sv`, `tb/tb_aes_sbox.sv`: self-checking testbenches
- `scripts/run.bat`, `scripts/sim.tcl`, `scripts/synth.tcl`: one-command sim + synthesis
- `constraints/ooc_100mhz.xdc`: 100 MHz clock for single-core synthesis

Results
- `tb_aes_sbox`: all 256 entries match the math definition; the S-box is a permutation.
- `tb_aes128_core`, all passed:
  - FIPS-197 C.1, FIPS-197 App. B, all-zero key/block and SP 800-38A F.1.1 (4 blocks)
  - 32 random vectors (expected values from Windows .NET AES)
  - Latency of 10 cycles to done; one block per 11 cycles back to back (~1.16 Gbit/s at 100 MHz)
  - start ignored while busy; inputs may change after start; output held after done; reset mid-block aborts cleanly
- Planted-bug check: a one-term MixColumns error is caught (fails on FIPS-197 C.1).
- Synthesis: 1,284 LUTs, 286 FFs, 0 BRAM, WNS +3.385 ns at 100 MHz. No latches. Only the usual out-of-context warnings.

Pre-purchase checks done so far
- Vivado 2026.1 has `xc7a35tcpg236-1` (Cmod A7-35T and Basys 3 chip) installed and licensed.
- The AES core fits easily and meets 100 MHz.

Issues found
- Vivado `opt_design` fails with an empty `Synth 20-411` error when its work folder is inside OneDrive. The scripts work in `%LOCALAPPDATA%\rover_fpga_build` instead.
- The Vivado license in use is an Enterprise license that Vivado says expires 22-Dec-2026. The free Standard edition should also cover the xc7a35t.

Not yet checked
- Python is not installed (needed for the GCM golden model and Wycheproof vectors). Solved later the same day: see below.
- Verilator is not installed (lint rule in project brief §6).

## 2026-10-27: project moved to C:\AES_128

- Vivado GUI simulation failed inside OneDrive: `compile.bat` failed after 0 s with "Spawn failed: The operation completed successfully". OneDrive locks the script Vivado writes just before running it.
- The project moved from the OneDrive Desktop to `C:\AES_128`. The project file is still `AES_Trial_1.xpr`.

## Phase 0, remaining steps (2026-10-27): ALL PASSED in simulation and synthesis

One command reruns everything: `scripts\run_all.bat` (vectors → 14 testbenches → 9 syntheses). The last full run printed `*** ALL PASSED ***`. Real Vivado numbers are in `docs/utilization.md`.

### Tools
- The golden model uses the Python 3.13 that ships with Vivado, in a project venv `.venv` with `cryptography` 50.0.2 (setup: `docs/how_to_test.md`, section F).
- Wycheproof AES-GCM vectors were downloaded from C2SP/wycheproof.
- Verilator is still not installed, so the lint rule is not yet applied. Vivado synthesis reports no latches on any core.

### Step 2: ghash + aes_gcm + Python golden model: PASSED
- Files:
  - RTL: `rtl/common/ghash.v`, `rtl/common/aes_gcm.v`
  - Testbenches: `tb/tb_ghash.sv`, `tb/tb_aes_gcm.sv`, `tb/common/gcm_iv_monitor.sv` (IV-reuse assertion)
  - Model: `model/gcm_model.py`, `model/gen_gcm_vectors.py`, `model/gen_ghash_vectors.py`
- GCM test cases 1–4 (McGrew–Viega): the published values were checked against the library first, then the RTL matches them.
- 349 random vectors match: 0–48 B AAD, 0–200 B text, including the real 18 B AAD + 640 B packet shape. Tampered tag, ciphertext and AAD (87 cases) are all rejected.
- 67 Wycheproof vectors match (128-bit key, 96-bit IV, 128-bit tag; 27 of them invalid and rejected).
- The tests run with random gaps on the input and stalls on the output.
- Bytes past the end of a message are ignored on input and zero on output.
- ECB mode gives FIPS-197 C.1.
- The IV-reuse monitor fires on a deliberate reuse and ignores decryptions and ECB calls.
- A 674-byte packet takes 6,179 cycles = 61.8 µs (~87 Mbit/s), far above the ~9.7 Mbit/s needed.
- Planted-bug check: one wrong bit in the GHASH reduction constant is caught (test case 2 fails).

### Step 3: motion_detect: PASSED
- Static scene + noise → 0 changed pixels.
- A 40×40 block moving 40 px → 3,200 changed pixels, motion = 1.
- An 8×8 change → 64 pixels, below the threshold → no motion.
- Frames while the motors run, and the frame after, are ignored.
- Extra pixels are ignored and alignment holds; the first frame after reset never reports motion.
- Exact counts are compared with a reference model.
- First synthesis failed timing (78 MHz) and used 24 BRAM. Fixed with 19 explicit 4K×8 banks and a 4-stage pipeline: 19 BRAM36, +3.0 ns.

### Step 4: ro_puf + puf_debias + fuzzy_extractor + puf_hash (+ puf_keygen): PASSED, with a sizing finding
- Behavioral RO model `tb/common/ro_cell_sim.sv`:
  - 1% process variation per chip
  - 0.15% noise per measurement and jitter
  - optional injected bias
- `tb_ro_puf`:
  - bits follow the RO frequencies
  - only the measured pair runs
  - same chip: 3.1% of bits differ; other chip: 46.9%
- `tb_puf_debias`: 75%-biased raw bits → 50.7% ones after VN; reconstruction selects the same pairs.
- `tb_fuzzy_extractor`: up to 2 errors per rep(5) block corrected; 3 errors fail, as they should.
- `tb_puf_hash`: matches the Python Davies–Meyer model for 680-, 128- and 50-bit inputs.
- `tb_puf_keygen`:
  - chip 1 enrolled, then 6 power-ups gave the same K (raw HD 3.6%, 0% after correction)
  - chip 2 with chip 1's helper data gave a different K (raw HD 49.5%)
  - a biased chip (24% ones) was stable over 4 power-ups
  - too few PUF bits raises `err`
- Synthesis: 1,280 real ROs (3 LUTs each, identical cells), 5,083 LUTs including an AES core, 100 MHz met.
- **Finding** (`docs/puf_entropy.md`): with the repetition code alone, no RO count that fits this FPGA gives a 128-bit key. VN debiasing multiplies the RO count by ~4.5. The feasible final design is BCH (e.g. BCH(255,91,25) ×2), without VN, with exact bias accounting: 500–1,500 ROs. **Decision for the supervisor.**
- The current defaults are a pipeline demo (24-bit entropy).

### Step 5: session_kdf + hello_fsm + trng_health (+ ro_trng): PASSED
- `trng_health`:
  - no false alarm in 200,000 random samples
  - RCT trips on exactly the 41st identical sample
  - APT trips at 90% ones and not at 68%
  - output blocked and failure sticky; no output after a start-up failure
- `ro_trng` (RO model): one bit per 64 cycles, passes the health tests, 49.1% ones, lag-1 correlation 0.005.
- `session_kdf`: K_s (20), GMAC incl. exact HELLO layouts (54, corrupted tags rejected) and TRNG conditioning (10) all match Python.
- `hello_fsm` (rover + base, each with its own GCM engine and a fatal IV-reuse monitor):
  - **same nonces → same K_s on both sides**
  - forged HELLO rejected
  - replayed HELLO never establishes a session and doesn't disturb the running one
  - replayed old base reply rejected
  - link loss → restart
  - base reboot → HELLO_REQ → new session
  - rover reboot → base keeps the old session until the new one is confirmed
  - wrong K → no session
  - blocked TRNG → no HELLO
  - the IV-reuse monitor never fired (16 tags generated)
- Protocol details decided here: `docs/session_protocol.md`. TRNG cutoffs: `docs/trng.md`.
- Over budget: `session_kdf` + `hello_fsm` = 1,743 LUTs against 200–400. Fixes are listed in `docs/utilization.md`, note 4.

### Design changes made during Phase 0
- `aes_gcm` got an `ecb` mode (one plain AES block) so the KDF and TRNG conditioning share its AES core. This saves a second AES core (~1,300 LUTs) per board.
- `ro_cell.v` lives in `rtl/common` (used by the PUF on the rover and the TRNG on both boards).
- `run.bat` retries synthesis once when Windows locks Vivado's temp folder (error 20-411; happened once).
- XSim 2026.1 crashes (EXCEPTION_ACCESS_VIOLATION) on queues of structs with field selects. Testbenches use plain bit vectors instead.

### Phase 0 open points
- PUF code: BCH decoder and final sizing after the Phase 4 bias measurement (supervisor decision on debiasing).
- Session block area reduction (Phase 3, when `rover_top` / `base_top` share one GCM engine).
- Verilator lint.

### Next: Phase 1 (needs hardware)
Camera → VGA on the Basys 3. Buy first: Basys 3, Cmod A7-35T, OV7670 without FIFO, 2× ESP32-S3-WROOM-1U (project brief §4).

## 2026-10-28: design decisions, hardware explorer, new PC

Decisions (written into the project brief)
- Bitstream security: **Option B** (documented limitation) on all main boards. Optional Option A demo on a spare Cmod in Phase 6, only with supervisor approval (§5.5).
- Traffic analysis is now in the threat model (§2, §5.9):
  - the packet type and the motion flag move into a 6-byte encrypted inner header; the readable header byte (`kind`) only says DATA / HELLO / HELLO_REQ
  - every rover DATA packet is 680 bytes (a multiple of 4), sent at a constant rate (`FPS_TX` × 120 per second, start at 8 fps); encrypted padding packets fill empty slots
  - no snapshot-on-motion mode; WPA3 instead of WPA2; new security test 13 (traffic shape)
  - No RTL change needed now: HELLO / HELLO_REQ keep their header values, so `hello_fsm` and `aes_gcm` are unchanged. The constant-rate packetizer is Phase 3 work.

Docs
- `docs/hardware-explorer.html`: interactive page (open in a browser). System map, threat table, packet layout, and one tab per Phase 0 block with schematics linked to the Verilog and working demos. Its AES / GCM code checks itself against FIPS-197 and GCM test cases 1–4 on load.
- Comments and docs now say "project brief §x" for references to the brief.

Working copy
- The repo is now at `D:\grad project\AES_128` on a second PC. This PC has **no Vivado and no `.venv` yet**: install Vivado 2026.1 (or set `VIVADO_BIN`) and follow `docs/how_to_test.md` section F before running `scripts\run_all.bat`. Then rerun it once to confirm Phase 0 still passes from the new folder (the path contains a space; if Vivado has trouble, clone to a path without spaces such as `D:\AES_128`).
