# Alternative parts and boards

Options to consider before buying (project brief §4: no boards bought yet). Prices and stock change, so check the vendor before ordering. Facts marked **(check)** are from memory and should be confirmed in the datasheet.

## 1. What any choice must meet

| Need | Why | Source |
|---|---|---|
| Xilinx 7-series (Artix-7 preferred) | All scripts, constraints and RTL target it; free Vivado; bitstream encryption (§5.5) | project brief §4 |
| Rover: ≥ ~25 BRAM36 and ≥ ~10,000 LUTs, more if the PUF needs it | Measured Phase 0 numbers plus remaining blocks | `docs/utilization.md` |
| Rover: small, battery powered, ≥ ~31 free I/O pins | Camera, ESP32 SPI, motors, servos | project brief §4 |
| Base: VGA output (or HDMI), buttons, ≥ ~12 BRAM36 | Video display and controls | project brief §5.6 |
| All 3.3 V logic | OV7670 and ESP32-S3 are 3.3 V; no level shifters | — |

## 2. FPGA boards

### Rover

| Board | Chip | LUTs / BRAM36 | Size | Rover use (est.) | Pros | Cons |
|---|---|---|---|---|---|---|
| **Digilent Cmod A7-35T** (current plan) | xc7a35t | 20,800 / 50 | 70×18 mm (DIP-48) | ~47% LUTs, ~44% BRAM | Tiny, breadboard-friendly, 512 KB SRAM, same chip as Basys 3 | The final PUF fits only with the "no debiasing" option (`docs/puf_entropy.md`) |
| **Alchitry Au+** | xc7a100t | 63,400 / 135 | ~65×45 mm | ~15% LUTs, ~16% BRAM | Small; all PUF options fit; video frame fits in BRAM, so no external memory needed | Needs the Alchitry "Br" breakout for pins; DDR3 (not SRAM) on board |
| Alchitry Au | xc7a35t | 20,800 / 50 | ~65×45 mm | same as Cmod | Small | No gain over the Cmod; no SRAM |
| **Digilent Arty A7-100T** | xc7a100t | 63,400 / 135 | ~110×87 mm | ~15% / ~16% | Best documented 100T board; Pmod and Arduino-style headers; easy wiring | Large and heavy on a small chassis |
| Digilent Arty A7-35T | xc7a35t | 20,800 / 50 | ~110×87 mm | same as Cmod | Easy headers | Bigger than the Cmod, no extra resources |
| QMTech Artix-7 100T core board | xc7a100t | 63,400 / 135 | small | ~15% / ~16% | Cheapest 100T | Thin documentation; pin files must be made by hand; quality varies by seller |
| Digilent Arty S7-50 | xc7s50 (Spartan-7) | 32,600 / 75 | ~110×87 mm | ~30% / ~30% | Middle size | Spartan-7 has no bitstream encryption **(check UG470)**, so Option A in §5.5 is ruled out |
| Digilent Cmod S7-25 | xc7s25 (Spartan-7) | 14,600 / 45 | DIP-48 | ~65% LUTs | Tiny | Too tight; no bitstream encryption **(check)** |

### Base

| Board | Chip | LUTs / BRAM36 | Display | Pros | Cons |
|---|---|---|---|---|---|
| **Digilent Basys 3** (current plan) | xc7a35t | 20,800 / 50 | VGA 12-bit | Common in universities; fits comfortably (~25% used) | VGA only |
| **Digilent Nexys A7-100T** | xc7a100t | 63,400 / 135 | VGA 12-bit | Same layout idea as Basys 3, 3× the resources; same chip as a 100T rover | Larger, costs more |
| Digilent Nexys Video / Arty + HDMI Pmod | xc7a200t / various | — | HDMI | Modern monitors | HDMI output core needed; more work |
| Laptop (fallback, §9) | — | — | screen | No second FPGA; reuses `/model` | Not hardware decryption |

### Not recommended

| Option | Why not |
|---|---|
| Zynq boards (Zybo Z7, PYNQ-Z2) | They contain an ARM CPU. The threat model says no CPU sees plaintext. Usable only if the CPU is left unused, which wastes the board. |
| Altera DE0-Nano | Too little block RAM for the frame buffer (project brief §4) |
| Altera DE10-Lite | Enough RAM, but a different vendor: new tools, constraints and scripts. Only if the lab lends it for free (§4). |
| Gowin boards (Sipeed Tang series) | Cheap, but different tools and libraries; the Vivado scripts won't carry over |

## 3. Camera

| Part | Interface | Pros | Cons |
|---|---|---|---|
| **OV7670 without FIFO** (current plan) | 8-bit parallel + SCCB | Cheapest; many FPGA examples; raw YUV suits motion detection | Must capture at pixel rate; needs pull-ups on SIOC/SIOD |
| OV7670 with AL422B FIFO | 8-bit parallel, frame stored on module | FPGA reads at its own pace; easier timing | More pins (FIFO control); fewer FPGA examples |
| OV2640 (DVP) | 8-bit parallel + SCCB | Up to 2 MP; built-in JPEG | JPEG frames are variable size and hard to motion-detect; more complex setup |
| OV5640 (DVP) | 8-bit parallel + SCCB | 5 MP, autofocus versions | Long register setup; overkill for 320×240 |
| Arducam mini (OV2640 + SPI) | SPI | Very simple wiring | Slow; JPEG only |
| Digilent Pcam 5C | MIPI CSI-2 | Good image | Needs MIPI support (Zynq/MIPI boards); not practical on Artix-7 |

Recommendation: keep the OV7670. Buy 2 in case one is damaged; they are cheap.

## 4. Wireless

| Part | Notes |
|---|---|
| **ESP32-S3-WROOM-1U** (current plan) | External antenna (u.FL) for range; SPI slave rated up to 60 MHz (project brief §4). Needs a carrier board or careful soldering. |
| ESP32-S3-DevKitC-1 (WROOM-1 version) | Development board with USB and pin headers; easiest to start with. PCB antenna gives shorter range. Good for Phase 3 bench tests. |
| ESP32-S3-DevKitC-1 with WROOM-1U | Dev-board convenience plus the external antenna; good final choice if available. |
| ESP32-C5 / ESP32-C6 | Newer chips (C5: dual-band 2.4/5 GHz, C6: Wi-Fi 6). Single core; SPI-slave speed and ESP-IDF support must be checked before choosing **(check)**. |
| Classic ESP32 | Avoid: SPI slave limited to 10 MHz (project brief §4). |
| nRF24L01+ / LoRa modules | Too slow for video. A LoRa link could be a separate long-range command/failsafe channel, but that is outside the current scope. |

Antenna: a 2.4 GHz dipole with u.FL-to-SMA pigtail for each WROOM-1U.

## 5. Drive and pan-tilt

| Part | Use | Notes |
|---|---|---|
| **TB6612FNG** module (current plan) | 2 motors | ~1.2 A continuous per channel, efficient, 3.3 V logic OK |
| DRV8833 module | 2 small motors | ~1.5 A per channel, 2.7–10.8 V motors; small and cheap |
| L298N module | 2 motors | Old design; ~2 V drop wastes battery; bulky. Only if already available |
| Cytron MDD3A / BTS7960 | Larger motors | For heavier chassis or 4WD with stronger motors |
| **SG90** servos (current plan) | Pan-tilt | Light, plastic gears |
| MG90S servos | Pan-tilt | Same size, metal gears, more durable |
| 2WD acrylic chassis + TT motors | Chassis | Cheapest; fine indoors |
| 4WD chassis | Chassis | Better traction; needs a driver per side (TB6612 handles 2 channels → pair motors per side) |
| Tracked (tank) chassis | Chassis | Best on rough ground; usually heavier |

## 6. Power

| Part | Use | Notes |
|---|---|---|
| 2S Li-ion (2× 18650) + buck converter to 5 V (e.g. LM2596 or MP1584 module) | Logic: FPGA board + ESP32 | Check the board's allowed input voltage in its reference manual **(check)** |
| USB power bank | Logic, simplest option | Some power banks switch off at low current; pick one without auto-off |
| Separate 2S Li-ion or 6× AA pack | Motors | Separate from logic, common ground (project brief §4) |
| 18650 holder with protection board, or protected cells | Safety | Over-discharge and short protection |
| Bulk capacitor (e.g. 470 µF) near the motor driver | Noise | Reduces resets when motors start |

## 7. Small parts

| Part | Use |
|---|---|
| 2× 4.7 kΩ resistors | Pull-ups on OV7670 SIOC/SIOD to 3.3 V |
| Jumper wires (short, female–female) | Camera and ESP32 wiring; keep the camera wires short |
| Breadboard or perfboard + pin headers | Rover wiring |
| VGA monitor + cable | Base display |
| 2× USB cables (micro-USB for Cmod/Basys 3, USB-C for ESP32-S3 dev boards) | Programming |

## 8. Suggested sets

| Set | Rover | Base | When to choose |
|---|---|---|---|
| **A: current plan** | Cmod A7-35T | Basys 3 | Lowest cost; the PUF must use the "no debiasing" option, which needs supervisor approval |
| **B: comfortable** | Alchitry Au+ (or Arty A7-100T) | Basys 3 | All PUF options fit; no external memory needed; little extra work |
| **C: same chip both sides** | Alchitry Au+ / Arty A7-100T | Nexys A7-100T | Most headroom on both boards; highest cost |

For all sets:
- OV7670 (no FIFO) ×2
- ESP32-S3 (WROOM-1U, or DevKitC-1 for bench tests) ×2
- TB6612FNG
- SG90 or MG90S ×2
- 2WD or 4WD chassis
- separate batteries for logic and motors

Changing boards needs only these changes:
- the part name in `scripts/synth.tcl`
- new pin constraints in `constraints/`
- re-running `scripts/run_all.bat`
- updating `docs/utilization.md` and the PUF sizing (`model/puf_entropy.py`)
