#!/usr/bin/env python3
"""Fill REPLACE_ME vault stubs in the Ansible inventory with real secrets.

Every secret in this repo is generated ahead of time and vault-encrypted in
place, so `just bootstrap` never has to stop and ask a human for a value
mid-flight. New wiring lands with a placeholder block:

    my_secret: !vault |
              $ANSIBLE_VAULT;1.1;AES256
              REPLACE_ME_WITH_ANSIBLE_VAULT_ENCRYPT_STRING_OUTPUT

This script finds those, generates a value, encrypts it, and splices the real
block in. It is idempotent: a var already holding real ciphertext is left
alone, so re-running never rotates a live secret.

The generator comes from the `openssl rand ...` command in the comment block
directly above each var, so the file stays the single source of truth. Only
`-hex N` / `-base64 N` are honoured -- nothing from the file is executed.
"""

import os
import re
import secrets
import subprocess
import sys
from base64 import b64encode
from pathlib import Path

STUB = "REPLACE_ME_WITH_ANSIBLE_VAULT_ENCRYPT_STRING_OUTPUT"
VAULT_OPEN = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*): !vault \|\s*$")
GENERATOR = re.compile(r"openssl\s+rand\s+(-hex|-base64)\s+(\d+)")
# A var whose comment says it must match something outside the vault (the
# Tofu .env) is useless if we only ever store it encrypted -- the plaintext
# has to reach the user too. See `sidecar` handling below.
MUST_MATCH = re.compile(r"[Mm]ust match")

DEFAULT_GEN = ("-hex", 32)


def generate(flag: str, n: int) -> str:
    """Mirror `openssl rand <flag> N | tr -d '\\n'` without shelling out."""
    raw = secrets.token_bytes(n)
    return raw.hex() if flag == "-hex" else b64encode(raw).decode()


def encrypt(name: str, value: str) -> list[str]:
    """Vault-encrypt one value. Plaintext goes over stdin, never argv."""
    proc = subprocess.run(
        ["ansible-vault", "encrypt_string", "--stdin-name", name],
        input=value,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"error: ansible-vault failed for {name}:\n{proc.stderr.strip()}")
    return proc.stdout.rstrip("\n").split("\n")


def comment_block_above(lines: list[str], idx: int) -> str:
    """Contiguous run of comment lines immediately preceding lines[idx]."""
    out = []
    i = idx - 1
    while i >= 0 and lines[i].lstrip().startswith("#"):
        out.append(lines[i])
        i -= 1
    return "\n".join(reversed(out))


def find_stubs(lines: list[str]):
    """Yield (start, end, indent, name, comment) for each placeholder block.

    `end` is exclusive and covers the block scalar's continuation lines --
    everything indented deeper than the `key: !vault |` line itself.
    """
    i = 0
    while i < len(lines):
        m = VAULT_OPEN.match(lines[i])
        if not m:
            i += 1
            continue
        indent, name = m.group(1), m.group(2)
        j = i + 1
        while j < len(lines) and (
            not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > len(indent)
        ):
            j += 1
        # Trailing blank lines belong to the file, not the block.
        while j - 1 > i and not lines[j - 1].strip():
            j -= 1
        if STUB in "\n".join(lines[i:j]):
            yield i, j, indent, name, comment_block_above(lines, i)
        i = j


def process(path: Path, sidecar: list[tuple[str, str, str]]) -> list[str]:
    lines = path.read_text().split("\n")
    filled = []
    # Right-to-left so earlier indices stay valid as we splice.
    for start, end, indent, name, comment in reversed(list(find_stubs(lines))):
        gm = GENERATOR.search(comment)
        flag, n = (gm.group(1), int(gm.group(2))) if gm else DEFAULT_GEN
        value = generate(flag, n)
        block = encrypt(name, value)
        # Re-indent to wherever this var actually sits, in case it is nested.
        base = len(block[0]) - len(block[0].lstrip())
        lines[start:end] = [
            indent + ln[base:] if ln.strip() else ln for ln in block
        ]
        filled.append((name, f"{flag} {n}"))
        if MUST_MATCH.search(comment):
            sidecar.append((str(path), name, value))
    if filled:
        path.write_text("\n".join(lines))
    return list(reversed(filled))


def main() -> int:
    root = Path(__file__).resolve().parent.parent / "ansible" / "inventory"
    if not os.environ.get("ANSIBLE_VAULT_PASSWORD_FILE"):
        sys.exit(
            "error: ANSIBLE_VAULT_PASSWORD_FILE is not set.\n"
            "       export ANSIBLE_VAULT_PASSWORD_FILE=infra/ansible/.vault-password"
        )

    sidecar: list[tuple[str, str, str]] = []
    total = 0
    for path in sorted(root.rglob("*.yml")):
        for name, gen in process(path, sidecar):
            print(f"  filled  {path.relative_to(root.parent.parent)}  {name}  ({gen})")
            total += 1

    if not total:
        print("  nothing to do -- no REPLACE_ME stubs found.")
        return 0

    print(f"\n{total} stub(s) filled.")

    if sidecar:
        # These have to be copied somewhere outside the vault by hand, so the
        # plaintext has to survive this script. A file (0600, gitignored via
        # *.env) beats printing to a terminal that keeps scrollback.
        out = Path(__file__).resolve().parent.parent / ".vault-plaintext.env"
        fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write("# Generated by `just fill-vault-stubs`. Copy these into\n")
            fh.write("# .env / terraform.tfvars, then DELETE THIS FILE.\n")
            for src, name, value in sidecar:
                fh.write(f"# {name} (from {src})\n{value}\n")
        print(f"\n{len(sidecar)} value(s) must also be copied outside the vault.")
        print(f"Plaintext written to {out} (0600) -- copy, then delete it.")

    print("\nReview with `git diff`, then commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
