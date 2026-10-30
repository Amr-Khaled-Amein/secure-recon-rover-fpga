"""
gcm_model.py : Python golden model for the rover's crypto (project brief §5).

Uses the `cryptography` library as the reference AES / AES-GCM. The RTL
testbenches compare against vectors produced from these functions, and the
laptop-base fallback (§9) reuses them.

Functions
  aes_block(key, block)           AES-128 single block encrypt
  gcm_encrypt(key, iv, pt, aad)   -> (ct, tag)
  gcm_decrypt(key, iv, ct, aad, tag) -> pt, or None if the tag is wrong
  packet_iv(direction, session_id, counter)   96-bit IV of §5.2
  hello_iv(tag_byte, nonce8)      IV for HELLO messages under K (§5.2)
  session_key(k, n_rover, n_base) K_s = AES_K(N_rover || N_base)
  davies_meyer(blocks)            hash used for privacy amplification (§5.3)
"""
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

DIR_ROVER_TO_BASE = 0x01
DIR_BASE_TO_ROVER = 0x02
HELLO_ROVER = 0x03
HELLO_BASE = 0x04


def aes_block(key: bytes, block: bytes) -> bytes:
    assert len(key) == 16 and len(block) == 16
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def gcm_encrypt(key: bytes, iv: bytes, pt: bytes, aad: bytes = b""):
    assert len(iv) == 12
    out = AESGCM(key).encrypt(iv, pt, aad)
    return out[:-16], out[-16:]


def gcm_decrypt(key: bytes, iv: bytes, ct: bytes, aad: bytes, tag: bytes):
    try:
        return AESGCM(key).decrypt(iv, ct + tag, aad)
    except InvalidTag:
        return None


def packet_iv(direction: int, session_id: bytes, counter: int) -> bytes:
    assert direction in (DIR_ROVER_TO_BASE, DIR_BASE_TO_ROVER)
    assert len(session_id) == 3
    return bytes([direction]) + session_id + counter.to_bytes(8, "big")


def hello_iv(tag_byte: int, nonce8: bytes) -> bytes:
    assert tag_byte in (HELLO_ROVER, HELLO_BASE) and len(nonce8) == 8
    return bytes([tag_byte]) + nonce8 + b"\x00\x00\x00"


def session_key(k: bytes, n_rover: bytes, n_base: bytes) -> bytes:
    assert len(n_rover) == 8 and len(n_base) == 8
    return aes_block(k, n_rover + n_base)


def davies_meyer(blocks, h0: bytes = bytes(16)) -> bytes:
    """H_i = AES_{m_i}(H_{i-1}) xor H_{i-1}; message blocks are the keys."""
    h = h0
    for m in blocks:
        assert len(m) == 16
        h = bytes(a ^ b for a, b in zip(aes_block(m, h), h))
    return h


# ---------------------------------------------------------------------------
# Session setup (project brief §5.2)
# ---------------------------------------------------------------------------
COND_KEY = b"rover-trng-cond0"          # fixed public conditioning key
MAGIC = 0x5256                          # "RV"
TYPE_VIDEO, TYPE_SNAPSHOT, TYPE_COMMAND, TYPE_MOTION, TYPE_HELLO, TYPE_HELLO_REQ = 1, 2, 3, 4, 5, 6


def condition(raw: bytes, key: bytes = COND_KEY) -> bytes:
    """AES CBC-MAC over raw TRNG bits (multiple of 16 bytes); X_0 = 0."""
    assert len(raw) % 16 == 0 and raw
    x = bytes(16)
    for i in range(0, len(raw), 16):
        x = aes_block(key, bytes(a ^ b for a, b in zip(x, raw[i:i + 16])))
    return x


def header(ptype: int, session_id: bytes, frame_no: int = 0, chunk_no: int = 0, counter: int = 0) -> bytes:
    """18-byte packet header (§5.1); authenticated as GCM AAD."""
    assert len(session_id) == 3
    return (MAGIC.to_bytes(2, "big") + bytes([ptype]) + session_id + frame_no.to_bytes(2, "big")
            + chunk_no.to_bytes(2, "big") + counter.to_bytes(8, "big"))


def hello_rover(k: bytes, n_rover: bytes):
    """Rover HELLO: header || N_rover, GMAC under K with IV 03||N_rover||000000."""
    hdr = header(TYPE_HELLO, n_rover[:3])
    _, tag = gcm_encrypt(k, hello_iv(HELLO_ROVER, n_rover), b"", hdr + n_rover)
    return hdr, tag


def hello_base(k: bytes, n_rover: bytes, n_base: bytes):
    """Base reply: header || N_rover || N_base, GMAC under K with IV 04||N_base||000000."""
    hdr = header(TYPE_HELLO, n_rover[:3])
    _, tag = gcm_encrypt(k, hello_iv(HELLO_BASE, n_base), b"", hdr + n_rover + n_base)
    return hdr, tag


# ---------------------------------------------------------------------------
# GHASH (SP 800-38D), written out so the ghash core can be tested alone.
# Checked against the library: gcm_tag_manual() must equal gcm_encrypt().
# ---------------------------------------------------------------------------
_R = 0xE1 << 120


def gf_mult(x: int, y: int) -> int:
    """x * y in GF(2^128), GCM bit order (bit 0 = MSB of byte 0)."""
    z, v = 0, y
    for i in range(127, -1, -1):
        if (x >> i) & 1:
            z ^= v
        v = (v >> 1) ^ _R if v & 1 else v >> 1
    return z


def ghash(h: bytes, blocks) -> bytes:
    y, hi = 0, int.from_bytes(h, "big")
    for b in blocks:
        y = gf_mult(y ^ int.from_bytes(b, "big"), hi)
    return y.to_bytes(16, "big")


def gcm_tag_manual(key: bytes, iv: bytes, ct: bytes, aad: bytes) -> bytes:
    pad = lambda b: b + bytes(-len(b) % 16)
    data = pad(aad) + pad(ct) + (8 * len(aad)).to_bytes(8, "big") + (8 * len(ct)).to_bytes(8, "big")
    h = aes_block(key, bytes(16))
    s = ghash(h, [data[i:i + 16] for i in range(0, len(data), 16)])
    ej0 = aes_block(key, iv + b"\x00\x00\x00\x01")
    return bytes(a ^ b for a, b in zip(s, ej0))
