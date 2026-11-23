#!/usr/bin/env python3
"""Hanna POS — license key banane ka tool (sirf Hanna Solutions ke paas; PRIVATE KEY kabhi app / repo mein nahi).

Istemal:
  pip install cryptography
  export HANNA_LICENSE_PRIVATE_KEY=<base64 private key>      # GitHub secret / apni file se
  python3 tools/license_tool.py issue --device ABCD-EFGH-IJKL-MNOP --plan yearly
  python3 tools/license_tool.py issue --device ABCD-EFGH-IJKL-MNOP --plan monthly --months 3
  python3 tools/license_tool.py issue --device ABCD-EFGH-IJKL-MNOP --plan lifetime
  python3 tools/license_tool.py issue --device ABCD-EFGH-IJKL-MNOP --plan days --days 45
  python3 tools/license_tool.py show  --key HP1-....        # key ke andar kya hai (check)
  python3 tools/license_tool.py keygen                       # NAYA jora (purani saari keys bekaar!)

Key ka format (lib/license/license_codec.dart ke bilkul mutabiq):
  16 byte payload + 64 byte Ed25519 signature -> base32 (A-Z2-7, bina '='), 4-4 ke group, "HP1-" se shuru.
  payload: [0]=version 1, [1]=plan (1 lifetime, 2 yearly, 3 monthly, 4 days), [2..3]=expiry din (2024-01-01 se,
  big-endian, 0 = lifetime), [4..5]=issue din, [6..15]=device ke 10 byte (Device ID ka base32 decode).
"""
import argparse
import base64
import datetime as dt
import os
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

EPOCH = dt.date(2024, 1, 1)
PLANS = {"lifetime": 1, "yearly": 2, "monthly": 3, "days": 4}
PLAN_NAMES = {v: k for k, v in PLANS.items()}


def b32(data: bytes) -> str:
    return base64.b32encode(data).decode().rstrip("=")


def unb32(text: str) -> bytes:
    t = "".join(ch for ch in text.upper() if ch.isalnum())
    t = t.replace("0", "O").replace("1", "I").replace("8", "B")  # aam ghalti: 0/O, 1/I, 8/B
    return base64.b32decode(t + "=" * (-len(t) % 8))


def group(s: str, n: int = 4) -> str:
    return "-".join(s[i:i + n] for i in range(0, len(s), n))


def device_bytes(device: str) -> bytes:
    try:
        raw = unb32(device)
    except Exception:
        raw = b""
    if len(raw) != 10:
        sys.exit(f"Device ID ghalat hai (16 harf chahiye, jaise ABCD-EFGH-IJKL-MNOP): {device}")
    return raw


def add_months(d: dt.date, months: int) -> dt.date:
    y, m = divmod(d.month - 1 + months, 12)
    y += d.year
    m += 1
    last = [31, 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    return dt.date(y, m, min(d.day, last))


def load_private() -> Ed25519PrivateKey:
    v = os.environ.get("HANNA_LICENSE_PRIVATE_KEY", "").strip()
    if not v:
        sys.exit("HANNA_LICENSE_PRIVATE_KEY set nahi (base64 private key).")
    seed = base64.b64decode(v)
    if len(seed) != 32:
        sys.exit("HANNA_LICENSE_PRIVATE_KEY ghalat (32 byte base64 chahiye).")
    return Ed25519PrivateKey.from_private_bytes(seed)


def make_key(priv: Ed25519PrivateKey, device: bytes, plan: int, expiry_day: int, issue_day: int) -> str:
    payload = bytes([1, plan]) + expiry_day.to_bytes(2, "big") + issue_day.to_bytes(2, "big") + device
    sig = priv.sign(payload)
    return "HP1-" + group(b32(payload + sig))


def decode_key(key: str):
    k = key.strip().upper()
    if k.startswith("HP1"):
        k = k[3:]
    raw = unb32(k)
    if len(raw) != 80:
        raise ValueError(f"key ki lambai ghalat ({len(raw)} byte)")
    return raw[:16], raw[16:]


def cmd_issue(a):
    priv = load_private()
    dev = device_bytes(a.device)
    start = dt.date.fromisoformat(a.start) if a.start else dt.date.today()
    plan = PLANS[a.plan]
    if a.plan == "lifetime":
        exp = 0
    else:
        if a.plan == "yearly":
            end = add_months(start, 12 * max(1, a.years))
        elif a.plan == "monthly":
            end = add_months(start, max(1, a.months))
        else:
            if not a.days or a.days < 1:
                sys.exit("--plan days ke saath --days N do")
            end = start + dt.timedelta(days=a.days)
        exp = (end - EPOCH).days
    issue = (dt.date.today() - EPOCH).days
    key = make_key(priv, dev, plan, exp, issue)
    # App mein expiry ka din band hota hai — aakhri chalne wala din us se ek pehle.
    till = "hamesha (lifetime)" if exp == 0 else (EPOCH + dt.timedelta(days=exp - 1)).isoformat()
    print(key)
    print(f"# Device: {group(b32(dev))}  Plan: {a.plan}  Valid till: {till}", file=sys.stderr)


def cmd_show(a):
    payload, sig = decode_key(a.key)
    ver, plan = payload[0], payload[1]
    exp = int.from_bytes(payload[2:4], "big")
    issue = int.from_bytes(payload[4:6], "big")
    print(f"version {ver}, plan {PLAN_NAMES.get(plan, plan)}, device {group(b32(payload[6:16]))}")
    print(f"issued {EPOCH + dt.timedelta(days=issue)}, valid till {'lifetime' if exp == 0 else EPOCH + dt.timedelta(days=exp - 1)}")
    pub_b64 = os.environ.get("HANNA_LICENSE_PUBLIC_KEY", "").strip()
    if pub_b64:
        try:
            Ed25519PublicKey.from_public_bytes(base64.b64decode(pub_b64)).verify(sig, payload)
            print("signature: THEEK")
        except Exception:
            print("signature: GHALAT")


def cmd_keygen(_):
    priv = Ed25519PrivateKey.generate()
    seed = priv.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    pub = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    print("PRIVATE (GitHub secret HANNA_LICENSE_PRIVATE_KEY, kisi ko na dein):", base64.b64encode(seed).decode())
    print("PUBLIC  (lib/license/license_config.dart > publicKeyB64):", base64.b64encode(pub).decode())


def main():
    p = argparse.ArgumentParser(description="Hanna POS license tool")
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("issue")
    i.add_argument("--device", required=True)
    i.add_argument("--plan", choices=list(PLANS), required=True)
    i.add_argument("--months", type=int, default=1)
    i.add_argument("--years", type=int, default=1)
    i.add_argument("--days", type=int, default=0)
    i.add_argument("--start", help="YYYY-MM-DD (default: aaj)")
    i.set_defaults(fn=cmd_issue)
    s = sub.add_parser("show")
    s.add_argument("--key", required=True)
    s.set_defaults(fn=cmd_show)
    k = sub.add_parser("keygen")
    k.set_defaults(fn=cmd_keygen)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
