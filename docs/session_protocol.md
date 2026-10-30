# Session setup protocol (as implemented)

This implements project brief §5.2. Modules: `rtl/common/hello_fsm.v` (protocol), `rtl/common/session_kdf.v` (crypto), `rtl/common/aes_gcm.v` (engine, shared). The Python reference is `model/gcm_model.py` (`hello_rover`, `hello_base`, `session_key`, `condition`).

## Messages

Every message starts with the 18-byte header of §5.1, which is authenticated as AAD:

| Field | Bytes | HELLO / HELLO_REQ value |
|---|---|---|
| magic | 2 | `0x5256` ("RV") |
| type | 1 | `0x05` HELLO, `0x06` HELLO_REQ |
| session_id | 3 | first 3 bytes of N_rover (HELLO_REQ: 0) |
| frame_no | 2 | 0 |
| chunk_no | 2 | 0 |
| counter | 8 | 0 |

| Message | Payload (plaintext, authenticated) | GMAC IV (under K) | AAD | Total |
|---|---|---|---|---|
| Rover HELLO | N_rover (8 B) | `03 ‖ N_rover ‖ 000000` | header ‖ N_rover (26 B) | 18 + 8 + 16 = 42 B |
| Base reply | N_rover ‖ N_base (16 B) | `04 ‖ N_base ‖ 000000` | header ‖ N_rover ‖ N_base (34 B) | 18 + 16 + 16 = 50 B |
| HELLO_REQ | none, no tag | none | none | 18 B |

The two HELLO types have different payload lengths and different IV prefixes, so one can never be accepted as the other.

## Rules

- `K_s = AES_K(N_rover ‖ N_base)`. Video and commands use only K_s.
- Nonces are 64 bits from the RO TRNG. The bits pass the SP 800-90B health tests (`trng_health`), then the AES CBC-MAC conditioner (4 × 128 raw bits, fixed public key `"rover-trng-cond0"`). The nonce is the upper 64 bits of the result.
- **Rover:**
  - It accepts a base reply only if the reply echoes the *current* N_rover, the session_id matches, and the GMAC verifies under K.
  - With no valid reply within T_REPLY (0.5 s), it sends a new HELLO with a new N_rover.
- **Pending and current sessions:**
  - A derived K_s is first *pending*. The rover already sends video under it.
  - Each side promotes pending to *current* only when the packet layer reports a packet that verified under the pending key (`confirm_pend`).
  - A pending session that isn't confirmed within T_CONFIRM (0.5 s) is discarded.
- **The base keeps its current session while a new one is pending.** So a replayed old rover HELLO (whose tag is valid) creates a pending session that is never confirmed and expires, and the live link isn't disturbed. The packet layer chooses the key by session_id and must report which key verified (`confirm_pend` or `confirm_cur`).
- **Rover link timeout:** no valid command for T_LINK (2 s) → new handshake.
- **Base reboot:** while the base has no session, it sends HELLO_REQ every T_REQ_PERIOD (0.5 s). The rover acts on HELLO_REQ at most once per T_REQ_HOLD (1 s) and only when it already has a session. HELLO_REQ is unauthenticated, so the worst it can do is trigger a new handshake (DoS is out of scope).
- **Verification runs the GCM engine in decrypt mode,** so the simulation IV-reuse monitor only counts tags this side generates.

## Packet-layer duties (Phase 3)

- The packet-layer counter starts at 0 for each new K_s and strictly increases.
- IV = `direction ‖ session_id ‖ counter`, with direction `01` = rover→base and `02` = base→rover.
- Report `confirm_pend` / `confirm_cur` after each packet that verifies.
- Drop packets whose session_id matches neither the current nor the pending session.

## Tested (tb/tb_hello_fsm.sv)

1. Normal handshake (same K_s and session_id on both sides, confirmed)
2. Forged HELLO
3. Replayed HELLO
4. Link loss, and a replayed old base reply
5. Base reboot
6. Rover reboot
7. Wrong K
8. Blocked TRNG

A fatal IV-reuse monitor runs on both GCM engines throughout, across reboots.
