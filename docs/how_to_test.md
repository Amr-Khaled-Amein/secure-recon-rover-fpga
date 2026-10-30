# How to test

The project folder on this PC is `D:\grad project\secure-recon-rover-fpga`. If you clone it somewhere else, use that folder wherever this guide says "project folder". A path without spaces (e.g. `D:\secure-recon-rover-fpga`) is safest for Vivado.

Needs on each PC: Vivado 2026.1 in `C:\AMDDesignTools\2026.1` (or set `VIVADO_BIN` to its `Vivado\bin` folder) and the Python environment from section F.

## A. One command (recommended)

1. Press **Windows key**, type `cmd`, press **Enter**. A Command Prompt opens.
2. Type this and press **Enter**:
   ```
   cd /d "D:\grad project\secure-recon-rover-fpga"
   ```
3. Run the S-box test (about 15 s):
   ```
   scripts\run.bat aes_sbox sim
   ```
   The last line must be `*** aes_sbox: ALL CHECKS PASSED ***`.
4. Run the AES core test, simulation then synthesis (about 2 min):
   ```
   scripts\run.bat aes128_core
   ```
   The end of the output must look like this:
   ```
   ==================== aes128_core on xc7a35tcpg236-1 ====================
   LUTs                 1284 / 20800   (6.17%)
   FFs                   286 / 41600   (0.69%)
   BRAM36                  0 / 50      (0.00%)
   DSPs                    0 / 90      (0.00%)
   Timing @100 MHz  WNS = 3.385 ns   (est. Fmax 151 MHz)
   *** aes128_core: ALL CHECKS PASSED ***
   ```
   WNS must be positive. A negative WNS means the design is too slow for 100 MHz.
5. If something fails, the message names the log to open:
   - `build\sim_<module>.log` and `build\sim\<module>\xsim.log` for simulation
   - `build\synth_<module>.log` and `build\synth\<module>\` for synthesis

Other forms:
- `scripts\run.bat aes128_core sim` runs simulation only.
- `scripts\run.bat aes128_core synth` runs synthesis only.
- Replace `aes128_core` with any module name from the table below.

## A2. All Phase 0 tests at once (about 25 min)

1. Open a Command Prompt and go to the project, as in section A, steps 1–2.
2. Type this and press **Enter**:
   ```
   scripts\run_all.bat
   ```
   It regenerates the test vectors with the Python model (section F), runs every testbench, then synthesizes every core.
3. Each step prints one line, `PASS ...` or `FAIL ...`. The last line must be `*** ALL PASSED ***`.
4. For a failed step, open the file named on its line, in `build\run_all\`.

`scripts\run_all.bat sim` runs only the vectors and simulations (about 10 min).

| Module | What its testbench checks |
|---|---|
| `aes_sbox`, `aes128_core` | FIPS-197 and NIST vectors, handshakes, latency |
| `ghash` | GHASH chains vs the Python model (which is checked against the `cryptography` library) |
| `aes_gcm` | GCM test cases 1–4, 349 random vectors (incl. 18 B AAD + 640 B packets), 67 Wycheproof vectors, tampered tag/ciphertext/AAD rejected, ECB mode, IV-reuse monitor |
| `motion_detect` | static / noise / moving block / tiny change / motors running / extra pixels |
| `ro_puf` | bits match the RO model; same chip ≈ same bits, other chip ≈ 50% different |
| `puf_debias`, `fuzzy_extractor`, `puf_hash` | VN debiasing, repetition-code correction, Davies–Meyer hash vs Python |
| `puf_keygen` | enrollment + 6 power-ups give the same key; other chip gives a different key; biased chip stable; out-of-bits error |
| `trng_health`, `ro_trng` | SP 800-90B RCT/APT: no false alarms, trip on stuck/biased input; TRNG source output |
| `session_kdf` | K_s, HELLO tags and TRNG conditioning vs Python |
| `hello_fsm` | rover + base handshake, forged/replayed HELLOs, link loss, reboots of either side, wrong key, TRNG failure |

Vivado's work files go to `%LOCALAPPDATA%\rover_fpga_build`. You can delete that folder at any time.

Keep the project out of OneDrive (and other synced folders such as Dropbox): Vivado's simulation and implementation fail inside them.

## B. Optional: prove the test catches bugs

1. Open `rtl\common\aes128_core.v` and find this line in the MixColumns section:
   `assign mc[127-32*c-24 -: 8] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);`
2. Change `(xtime(a0) ^ a0)` to `xtime(a0)` and save.
3. Run `scripts\run.bat aes128_core sim`. It must fail with
   `Fatal: [FIPS-197 C.1] MISMATCH` and `*** SIMULATION FAILED ***`.
4. Undo the change and run it again. It must pass.

## C. Same simulation in the Vivado GUI (once, to see waveforms)

1. Start **Vivado 2026.1** from the Start menu.
2. **File > Project > Open...**, choose `AES_Trial_1.xpr` in the project folder, click **OK**.

   The files are already added to this project, so skip to step 9. Steps 3–8 are only for a new project.
3. In the **Flow Navigator** (left), under **PROJECT MANAGER**, click **Add Sources**.
4. Choose **Add or create design sources**, click **Next**.
5. Click **Add Files**, select `rtl\common\aes128_core.v` and `rtl\common\aes_sbox.v`, click **OK**.
6. **Untick** "Copy sources into project", click **Finish**.
7. Click **Add Sources** again, choose **Add or create simulation sources**, click **Next**.
8. Click **Add Files**, select `tb\tb_aes128_core.sv`, click **OK**, untick "Copy sources into project", click **Finish**.
9. In the **Sources** window, open **Simulation Sources > sim_1**, right-click **tb_aes128_core**, choose **Set as Top**.
10. In the Flow Navigator, under **SIMULATION**, click **Run Simulation > Run Behavioral Simulation**.
11. When the waveform window opens, type `run all` in the **Tcl Console** at the bottom and press **Enter**.
12. The console must show `TEST PASSED`. Drag signals from the **Scope/Objects** panes into the waveform to look at them.


## D. Interactive demo: type a message, get the ciphertext

1. In Vivado with `AES_Trial_1.xpr` open, close any running simulation first: **File > Close Simulation**. Click **OK** if Vivado asks.
2. `demo_aes128.sv` is already in the project; skip this step. In a new project, add it with **PROJECT MANAGER > Add Sources > Add or create simulation sources > Next > Add Files**: select `tb\demo_aes128.sv`, click **OK**, untick "Copy sources into project", click **Finish**.
3. In **Sources**, expand **Simulation Sources > sim_1**, right-click **demo_aes128**, and choose **Set as Top**.
4. Click **SIMULATION > Run Simulation > Run Behavioral Simulation** and wait for the waveform window.
5. In the **Tcl Console**, type each line and press **Enter**:
   ```
   source {D:/grad project/secure-recon-rover-fpga/scripts/aes_demo.tcl}
   ```
   Use your project folder with forward slashes; keep the braces `{ }` when the path has spaces.
   ```
   aes_selftest
   aes_encrypt "hello world"
   ```
6. Expected output with the default key (`000102...0f`):
   ```
   SELFTEST PASSED: FIPS-197 C.1 -> 69c4e0d86a7b0430d8cdb78070b4c55a
   ciphertext : 9276fdf384f38518fa6c8310f191678d
   ```
7. To use your own key (exactly 16 characters, or 32 hex digits):
   ```
   aes_key "my secret key 16"
   aes_encrypt "hello world"
   ```
   Expected: `ciphertext : 870202b8d8895865d33cf7ea73c51dbd`

Each block appears in the waveform window too: `start` pulses, `done` pulses 10 cycles later, and `block_out` shows the ciphertext.

To check a result outside Vivado, use any AES tool set to **AES-128, ECB mode, PKCS#7 padding** with the same key in hex. For example, CyberChef's "AES Encrypt" with Key = Hex, Mode = ECB, Input = UTF8, Output = Hex.

To go back to the self-checking test: right-click **tb_aes128_core > Set as Top** and run the simulation again.

## E. If the GUI simulation fails at "compile" or "elaborate"

Typical errors are `'compile' step failed`, `Spawn failed: ...` or `Failed to open file to read (elaborate.log)`. They come and go on this PC: the same run passes on the next try. The most likely cause is Windows Defender scanning the files Vivado has just generated (`compile.bat`, `xsimk.exe`) at the moment Vivado runs them.

1. Retry first: **File > Close Simulation**, wait about 10 s, then **Run Behavioral Simulation** again.
2. Still failing? Close Vivado, delete the folder `AES_Trial_1.sim` in the project folder (Vivado rebuilds it), start Vivado and try again.
3. To stop it for good, add Defender exclusions (needs an administrator account):
   1. Press **Windows key**, type `Windows Security`, press **Enter**.
   2. Click **Virus & threat protection**.
   3. Under **Virus & threat protection settings**, click **Manage settings**.
   4. Scroll to **Exclusions** and click **Add or remove exclusions**. Click **Yes** in the prompt.
   5. Click **Add an exclusion > Folder**, choose the project folder, click **Select Folder**.
   6. Repeat step 5 for `%LOCALAPPDATA%\rover_fpga_build` (type that into the folder bar; it opens your own AppData folder). Create the folder first if it doesn't exist.
4. `scripts\run.bat` (section A) has not failed this way, so use it whenever the GUI misbehaves.

## F. Python golden model (one-time setup on each PC)

The test vectors in `model\vectors` come from Python's `cryptography` library. The project uses its own Python environment in `.venv` inside the project folder (not stored in git), built from the Python that ships with Vivado. To rebuild it (for example on another PC):

1. Open a Command Prompt and type:
   ```
   cd /d "D:\grad project\secure-recon-rover-fpga"
   C:\AMDDesignTools\2026.1\tps\win64\python-3.13.0\python.exe -m venv .venv
   .venv\Scripts\python -m pip install cryptography
   ```
2. Regenerate all vectors:
   ```
   .venv\Scripts\python model\gen_gcm_vectors.py
   .venv\Scripts\python model\gen_ghash_vectors.py
   .venv\Scripts\python model\gen_puf_vectors.py
   .venv\Scripts\python model\gen_session_vectors.py
   ```
   `scripts\run_all.bat` also does step 2 for you.
3. PUF sizing tables: `.venv\Scripts\python model\puf_entropy.py` (see `docs\puf_entropy.md`).

The Wycheproof file `model\vectors\aes_gcm_test.json` was downloaded from https://github.com/C2SP/wycheproof (`testvectors_v1/aes_gcm_test.json`).
