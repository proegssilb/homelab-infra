#!/usr/bin/env python3
"""Generate a random secret straight into Bitwarden (folder "homelab").

    scripts/bw-run -- scripts/bw-generate.py NAME [--bytes 32] [--hex]

Prints the item name and whether it was created; never the value. Refuses to
overwrite an existing item (rotate by deleting it in Bitwarden first).
"""
import argparse
import base64
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bwlib  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("name")
    ap.add_argument("--bytes", type=int, default=32)
    ap.add_argument("--hex", action="store_true", help="hex instead of base64")
    args = ap.parse_args()
    if not os.environ.get("BW_SESSION"):
        sys.exit("error: no BW_SESSION; run under scripts/bw-run")
    vault = bwlib.Vault()
    if vault.exists(args.name):
        print(f"{args.name}: exists (left alone)")
        return 0
    raw = secrets.token_bytes(args.bytes)
    vault.create(args.name, raw.hex() if args.hex else base64.b64encode(raw).decode())
    print(f"{args.name}: created")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except bwlib.BitwardenError as e:
        sys.exit(f"error: {e}")
