# Code guide (for Verilog beginners)

This guide explains the project's code step by step. Read Part 1 first if Verilog is new to you. Part 3 then walks through each module in the order the data flows.

> **Kept up to date:** this file is updated whenever the code changes significantly. The change log at the end lists what changed and when.
> **Last updated:** 2026-10-27 (end of Phase 0).

---

## Part 1: Verilog in 10 minutes, using this project's code

### 1.1 Hardware, not a program

Verilog *describes circuits*. It is not a list of instructions run one after another.
- Every `assign` line and every `always` block is a piece of hardware.
- All of them work **at the same time**, all the time.
- A clock (`clk`, 100 million ticks per second here) tells the memory elements when to update.

### 1.2 A module = a chip with pins

```verilog
module aes_sbox (
    input  wire [7:0] x,     // 8 input wires (one byte)
    output wire [7:0] y      // 8 output wires
);
    ...
endmodule
```

- `[7:0]` means 8 wires numbered 7 down to 0. Bit 7 is the most significant.
- A module is used by **instantiating** it, like placing a chip on a board and wiring its pins:

```verilog
aes_sbox u_sbox (.x(state[127:120]), .y(sb[127:120]));
//  type  name     pin x ← these wires   pin y → these wires
```

### 1.3 `wire` and `reg`

| Keyword | What it is | Example |
|---|---|---|
| `wire` | A connection. Its value is whatever drives it, right now. | `wire ro_a = ro_out[...];` |
| `reg` | Something assigned inside an `always` block. It is a flip-flop (memory) if the block is clocked; a plain wire if the block is `always @(*)`. | `reg [3:0] round;` |

### 1.4 Two kinds of logic, with the project's rules

**Combinational logic:** the output depends only on the current inputs, with no memory. It is written with `assign` or `always @(*)` and uses `=`.

```verilog
assign tag_match = (tag == tag_in);              // 1 when the two tags are equal

always @(*) begin                                 // majority vote (fuzzy_extractor)
    ones = 4'd0;                                  // default first: avoids "latches"
    for (k = 0; k < R; k = k + 1) ones = ones + {3'd0, y[k]};
    s = (ones > HALF);
end
```

**Sequential logic:** flip-flops that change only on the clock edge. It is written with `always @(posedge clk)` and uses `<=`.

```verilog
always @(posedge clk) begin
    if (rst) begin
        count <= 17'd0;          // synchronous reset: checked on the clock edge
    end else begin
        count <= count + 17'd1;  // new value appears after the clock edge
    end
end
```

Why `<=`? All `<=` assignments in a clocked block happen together at the clock edge. That is how real flip-flops behave. So `a <= b; b <= a;` swaps them.

Project rules (project brief §6):
- Never mix `=` and `<=` in one block.
- Every combinational block sets a default value first.
- Every constant has a width (`8'd0`, not `0`).

### 1.5 Number formats

`8'h1b` = 8 bits, hex 1b. `4'd10` = 4 bits, decimal 10. `1'b1` = 1 bit, binary 1. `{a, b}` joins wires side by side (concatenation). `{8{1'b1}}` repeats: eight 1s.

### 1.6 State machines (FSMs)

Most modules here are **finite state machines**: a `state` register remembers which step the module is in, and a `case` statement says what to do in each step.

```verilog
case (state)
    S_IDLE: if (start) state <= S_H;         // wait for a request
    S_H:    if (aes_done) state <= S_J0;     // wait for AES to finish
    ...
endcase
```

### 1.7 Handshakes: how modules pass data

| Style | Signals | Meaning |
|---|---|---|
| start/done | `start` in, `ready` out, `done` out | Pulse `start` while `ready` = 1; a `done` pulse later means the result is valid |
| valid/ready | `valid` from the sender, `ready` from the receiver | Data moves on a clock edge where **both** are 1. Either side can pause. |

### 1.8 Parameters and `generate`

```verilog
module ro_puf #(parameter N_RO = 1280) ( ... );   // the size is a setting
genvar i;
generate
    for (i = 0; i < N_RO; i = i + 1) begin : g_ro  // builds N_RO copies
        ro_cell u_ro (...);
    end
endgenerate
```

`generate` loops build hardware; they don't run in time. This one makes 1,280 ring oscillators.

### 1.9 Bits and bytes in this project

128-bit values follow the order of the standards: **bit 127 is the first bit of byte 0**. So `block[127:120]` is byte 0, `block[119:112]` is byte 1, and so on. That is why hex test vectors from FIPS-197 or GCM papers can be pasted in as written.

### 1.10 Every file starts and ends the same way

```verilog
`default_nettype none     // a misspelled signal name becomes an error...
...
`default_nettype wire     // ...instead of silently creating a new wire
```

Each file starts with a comment block: **Purpose**, **Ports**, **Latency** (how many clock cycles it takes).

---

## Part 2: Map of the project

```
rtl/common/   used on both boards: crypto, TRNG, session setup
rtl/rover/    rover only: motion detection, PUF
tb/           testbenches (.sv): one per module, self-checking
tb/common/    testbench helpers: IV-reuse monitor, ring-oscillator model
model/        Python golden models and test-vector generators
scripts/      run.bat / run_all.bat / sim.tcl / synth.tcl
docs/         results, explanations (this file)
```

How the Phase 0 modules connect:

```
                        ┌────────────── aes_gcm ──────────────┐
 video / commands ────► │  aes128_core (+ aes_sbox ×20)        │ ──► encrypted packets
                        │  ghash                               │
                        └──────────────▲───────────────────────┘
                                       │ shared AES engine
 ro_trng ► trng_health ► session_kdf ──┘
                              ▲
                          hello_fsm  ◄── HELLO messages to/from the other board
                              ▲
                              K (long-term key)
                              │
 ro_puf ► puf_debias ► fuzzy_extractor ► puf_hash   (= puf_keygen, rover only)

 camera pixels ► motion_detect ► "motion!" flag     (rover only)
```

---

## Part 3: Module by module

For each module: **what it does → how it works → how it is tested**.

### 3.1 `aes_sbox`: the AES substitution box (`rtl/common/aes_sbox.v`)

**What:** replaces one byte with another from a fixed 256-entry table (FIPS-197). This is the only "non-linear" step of AES; without it AES would be easy to break.

**How:** an `always @(*)` block with a `case` statement of 256 lines (`8'h00: s = 8'h63; ...`). The attribute `(* rom_style = "distributed" *)` tells Vivado to build it from LUTs instead of block RAM, which is kept for the frame buffers.

**Tested by:** `tb_aes_sbox` computes every entry from the mathematical definition and compares all 256.

### 3.2 `aes128_core`: AES-128 encryption (`rtl/common/aes128_core.v`)

**What:** encrypts one 16-byte block with a 16-byte key. It takes 11 clock cycles: 1 for the start, then 10 rounds.

**How, step by step:**

1. **Start** (`start && !busy`): the state becomes `block_in ^ key` (round 0, "AddRoundKey"). `round` is set to 1.
2. **Each clock while busy**, the circuit computes one full round:
   - **SubBytes:** 16 `aes_sbox` instances replace every byte.
   - **ShiftRows:** pure wiring, no gates. Row r of the 4×4 byte grid moves left by r.
     ```verilog
     assign sr[...(4*c+r)...] = sb[...(4*((c+r)%4)+r)...];
     ```
   - **MixColumns:** mixes the 4 bytes of each column using `xtime` (multiply by 2 in AES arithmetic):
     ```verilog
     function [7:0] xtime; input [7:0] a;
         xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);   // shift left, fix overflow
     endfunction
     ```
     Round 10 skips MixColumns, which is why the code has `(round == LAST_ROUND) ? sr : mc`.
   - **AddRoundKey:** XOR with the round key.
3. **On-the-fly key expansion:** the round keys are not stored. Each clock computes the next one (`rk_next`) from the previous one, using 4 more S-boxes and the round constant `rcon`.
4. After round 10: `busy` goes to 0, `done` pulses for one cycle, and `block_out` holds the ciphertext.

**Encrypt only:** the GCM mode (below) decrypts by *encrypting* a counter, so no AES decryption circuit is needed.

**Tested by:** `tb_aes128_core`: FIPS-197 and NIST vectors, 32 random vectors, timing, reset in the middle of a block.

### 3.3 `ghash`: the authentication math for GCM (`rtl/common/ghash.v`)

**What:** GCM needs a tag that proves a message wasn't changed. The tag is built with GHASH, which repeats `Y ← (Y xor X) × H` for every 16-byte block X. H is a secret value derived from the key, and "×" is multiplication in a special 128-bit number system, GF(2¹²⁸).

**How (bit-serial: one bit per clock, 128 clocks per block):**

```verilog
wire [127:0] z_next = a[127] ? (z ^ v) : z;                 // if this bit is 1, add V
wire [127:0] v_next = v[0] ? ((v >> 1) ^ R) : (v >> 1);     // V = V × x  (shift + reduce)
```

This is schoolbook multiplication: for each bit of `a = Y xor X`, add the shifted H if the bit is 1. `R` (`0xE1 000…`) keeps the result at 128 bits. Doing one bit per clock keeps the circuit small (269 LUTs). It is still about 100 Mbit/s, far more than the video needs.

**Tested by:** `tb_ghash`, against a Python GHASH that is itself checked against the `cryptography` library.

### 3.4 `aes_gcm`: authenticated encryption (`rtl/common/aes_gcm.v`)

**What:** encrypts (or decrypts) a packet *and* computes its 16-byte tag. The 18-byte header is not encrypted but is protected by the tag; it is called the AAD ("additional authenticated data").

**How, as a state machine:**

| State | What happens |
|---|---|
| `S_IDLE` | Wait for `start`; save key, IV, lengths |
| `S_H` | AES of all-zeros → **H** (for GHASH) |
| `S_J0` | AES of `IV‖00000001` → **E(J0)** (used at the end to hide the tag) |
| `S_AAD`, `S_AAD_GH` | Take each header block, GHASH it |
| `S_TXT`, `S_TXT_AES` | Take a text block; AES of `IV‖counter` gives the **keystream**; output = input XOR keystream |
| `S_TXT_GH`, `S_TXT_OUT` | GHASH the *ciphertext*; wait until the output was taken |
| `S_LEN`, `S_LEN_GH` | GHASH one last block holding the lengths |
| back to `S_IDLE` | `tag = GHASH result XOR E(J0)`, `done` pulse |
| `S_ECB_IN`, `S_ECB` | Extra mode: one plain AES block, used by `session_kdf` |

Points to notice:
- **Decryption is the same circuit.** XOR with the same keystream undoes the encryption. Only the GHASH input changes: it always hashes the ciphertext.
- **Partial blocks:** a message rarely fills its last 16-byte block. The function `byte_mask` zeroes the unused bytes.
- **Safety rule:** in decrypt mode, `out_data` is *unverified*. The receiver must keep it in a buffer and use it only if `tag_match` = 1 at the end.

**Tested by:** `tb_aes_gcm`:
- the official test cases and 349 random vectors
- 67 Wycheproof vectors
- tampered messages (all rejected)
- random pauses on input and output
- the IV-reuse monitor (`tb/common/gcm_iv_monitor.sv`): reusing an IV under the same key breaks GCM completely, and the monitor stops the simulation if it ever happens

### 3.5 `motion_detect`: is something moving? (`rtl/rover/motion_detect.v`)

**What:** compares each camera pixel with the same pixel in the previous frame. If enough pixels changed by enough, it reports motion.

**How:**
1. **Frame buffer:** 19 banks of 4,096 bytes = one 320×240 frame in block RAM.
   ```verilog
   for (b = 0; b < NBANK; b = b + 1) begin : g_bank
       reg [7:0] mem [0:4095];          // Vivado turns this into one BRAM block
   ```
   An earlier version used one big array; Vivado then used 24 blocks and was too slow.
2. **Pipeline:** each pixel moves through 4 stages, one per clock, so a new pixel can enter every clock:
   1. read the old pixel
   2. pick the right bank
   3. `|new − old| > PIX_THRESH`?
   4. add to `count`

   The new pixel is written over the old one.
3. **End of frame** (`eof`): `motion = count > AREA_THRESH`.
4. **Ignored frames:** motion is not reported on the first frame after reset (nothing to compare with). It is also not reported while `suppress` = 1 (motors running), or in the frame after.

**Tested by:** `tb_motion_detect`, with synthetic frames: static, noisy, moving block, tiny change, motors running.

### 3.6 The PUF chain (rover): `ro_cell` → `ro_puf` → `puf_debias` → `fuzzy_extractor` → `puf_hash`, wrapped by `puf_keygen`

The idea is explained in plain language in `docs/puf_entropy.md` (and in this project's chat history). The code:

**`ro_cell`** (`rtl/common/ro_cell.v`): one ring oscillator, three inverting gates in a loop:
```verilog
assign s0 = ~(en & s2);   // NAND: en = 0 stops the ring
assign s1 = ~s0;
assign s2 = ~s1;          // feeds back to s0 → oscillates
```
This is the *only* place where a combinational loop is allowed. A simulator can't run this zero-delay loop, so testbenches use `tb/common/ro_cell_sim.sv`, a model with realistic, chip-specific speeds and noise.

**`ro_puf`:** measures pair (2p, 2p+1):
1. **`S_SEL`:** select the pair and wait to settle; record both counters.
2. **`S_RUN`:** run both ROs for `WINDOW` clocks.
3. **`S_STOP`:** stop them and wait; compute the counts `da` and `db`.
4. Repeat `VOTES` times. **`S_OUT`:** the bit is 1 if RO 2p won the majority.

The counters are clocked by the RO itself (`always @(posedge ro_a)`). They are read only while the ROs are stopped, so their values are stable.

**`puf_debias`:** Von Neumann debiasing, done in pairs of bits:
- enrollment: keep the first bit if the two differ, and output a "mask" bit saying whether this pair was kept
- normal use: read the stored mask to know which pairs to keep

**`fuzzy_extractor`:** repetition-code error correction:
- enrollment: stores `w_i = x_i XOR x_0` (helper data)
- normal use: flips the noisy bits back with a majority vote

**`puf_hash`:** packs the corrected bits into 128-bit blocks and hashes them with AES (Davies–Meyer): `H = AES_m(H) XOR H` → the key K.

**`puf_keygen`:** connects all four with valid/ready handshakes. `ENROLL = 1` builds the lab-only enrollment version, which *outputs* helper data. `ENROLL = 0` is the deployed version, which *reads* it.

**Tested by:**
- one testbench per module
- `tb_puf_keygen`: enroll a simulated chip; 6 power-ups give the same key; another chip gives a different key

**Known problem:** the current settings give only 24 bits of key strength (see `docs/puf_entropy.md`).

### 3.7 Random numbers: `ro_trng` and `trng_health`

**`ro_trng`:** 4 ring oscillators XORed and sampled by the clock every 64 cycles. Their timing jitter (tiny random wobble) makes the samples random. The sample passes through two flip-flops (`s1`, `s2`) because the RO signal isn't synchronized to the clock. This 2-flop synchronizer is the standard safe way to bring an outside signal in.

**`trng_health`:** NIST tests that run all the time:
- **Repetition Count Test:** 41 equal bits in a row → fail
- **Adaptive Proportion Test:** in every 1,024 bits, the first bit's value appearing ≥ 793 times → fail

On failure, no more random bits are output until reset.

### 3.8 Session setup: `session_kdf` and `hello_fsm`

**`session_kdf`:** a "crypto service" that uses the shared `aes_gcm`:
- `OP_NONCE`: mixes 512 random bits into a 64-bit nonce
- `OP_KDF`: `K_s = AES_K(N_rover ‖ N_base)`
- `OP_GMAC`: computes or checks a HELLO tag

**`hello_fsm`:** the handshake rules, for the rover (`ROLE = 0`) or the base (`ROLE = 1`). Rover steps:

| State | Action |
|---|---|
| `R_START` → `R_GOT_NONCE` | Get random N_rover; compute the HELLO tag |
| `R_GOT_TAG` → `R_TX` | Send HELLO |
| `R_WAIT_REPLY` | Accept only a reply that echoes *this* N_rover; time out → new HELLO |
| `R_GOT_VERIFY` | Check the reply's tag; bad → ignore it |
| `R_GOT_KDF` → `R_PEND` | Derive K_s; wait for the first valid command |
| `R_EST` | Session running; restart after 2 s with no valid command, or on HELLO_REQ |

The `call` task stores the arguments for `session_kdf`, then jumps to `S_CALL`/`S_WAIT`. When the result arrives, it returns to the state saved in `ret`, a simple "subroutine call" for hardware.

The base keeps its old session until the new one is confirmed. So a replayed HELLO can't break a running link. Full rules: `docs/session_protocol.md`.

**Tested by:** `tb_hello_fsm`: a rover and a base talking through a simulated radio where the testbench forges, drops and replays messages, and reboots either side.

---

## Part 4: Testbenches, models and scripts

### 4.1 How a self-checking testbench works

A testbench (`tb/tb_<module>.sv`) is not hardware. It is a SystemVerilog program that:
1. creates a clock: `always #5 clk = ~clk;` gives a 10 ns period, i.e. 100 MHz
2. instantiates the module under test (`dut`)
3. drives inputs, waits with `@(negedge clk)`, reads outputs
4. compares with expected values; on any mismatch: `$fatal(...)`, which stops everything
5. at the end prints `TEST PASSED`

The scripts treat a run as passing only if `TEST PASSED` appears and no `Fatal` or `ERROR` does.

### 4.2 Where the expected values come from

`model/*.py` use Python's `cryptography` library, an independent and trusted AES/GCM implementation, to write test vectors into `model/vectors/*.txt`. The testbenches read them with `$fscanf`. If the hardware and Python agree on hundreds of random cases, the hardware is very likely right.

### 4.3 Scripts

| Command | What it does |
|---|---|
| `scripts\run.bat <module> sim` | Compile all RTL + `tb_<module>.sv`, run XSim, check for `TEST PASSED` |
| `scripts\run.bat <module> synth` | Synthesize, place and route for the FPGA; report LUTs, BRAM, timing |
| `scripts\run_all.bat` | Regenerate vectors, run every testbench, synthesize every core |

Step-by-step instructions: `docs/how_to_test.md`.

---

## Part 5: Glossary

| Term | Meaning |
|---|---|
| LUT | Look-up table: the FPGA's basic logic cell (any function of 6 inputs) |
| FF | Flip-flop: stores 1 bit, updates on the clock edge |
| BRAM | Block RAM: 36-kbit memory blocks inside the FPGA |
| Latency | Clock cycles from input to result |
| WNS | Worst negative slack: timing margin. Positive = fast enough for 100 MHz |
| IV / nonce | A number used once per encryption; must never repeat under the same key |
| Tag | 16-byte checksum that proves a packet wasn't changed |
| AAD | Data that is authenticated by the tag but not encrypted (our header) |
| Helper data | Public data stored on the rover that lets the PUF correct its noisy bits |
| Enrollment | One-time lab step that creates the helper data and gives K to the base |

---

## Change log

| Date | Change | Sections updated |
|---|---|---|
| 2026-10-27 | First version: all Phase 0 modules (AES, GHASH, GCM, motion detection, PUF chain, TRNG, session setup) | All |
