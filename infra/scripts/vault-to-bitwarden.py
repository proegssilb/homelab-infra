#!/usr/bin/env python3
"""Copy every ansible-vault value in the inventory into Bitwarden.

    scripts/bw-run -- scripts/vault-to-bitwarden.py [--dry-run] [--update NAME ...]

Until Phase 6 of the bootc migration (docs/specs/2026-11-22-bootc-migration.md)
the vault stays authoritative for Ansible; Bitwarden holds a copy that bootc VMs
read once they migrate. Re-run after rotating a vaulted secret: the item shows up
as exists-DIFFERENT, and `--update NAME` overwrites it.

Item names are `<scope>/<var>`, scope being the host or group the vars file
belongs to (group_vars/obs_prometheus.yml -> obs_prometheus,
host_vars/blade02.yml -> blade02, group_vars/proxy/main.yml -> proxy). Values
nested in lists/maps get the path appended: `<scope>/<var>/<index>/<key>`.

Prints item names and a status word only, never a value. Plaintext travels
ansible-vault stdout -> this process -> bw stdin. --dry-run decrypts nothing and
does not need Bitwarden.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bwlib  # noqa: E402

INVENTORY = Path(__file__).resolve().parent.parent / "ansible" / "inventory"
STUB = "REPLACE_ME_WITH_ANSIBLE_VAULT_ENCRYPT_STRING_OUTPUT"


class Vaulted(str):
    """Ciphertext of one `!vault |` value."""


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("!vault", lambda loader, node: Vaulted(loader.construct_scalar(node)))


def scope_of(path: Path) -> str:
    rel = path.relative_to(INVENTORY)
    # group_vars/<scope>.yml or group_vars/<scope>/<anything>.yml
    return rel.parts[1] if len(rel.parts) > 2 else rel.stem


def walk(obj, prefix):
    if isinstance(obj, Vaulted):
        yield prefix, obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield from walk(v, f"{prefix}/{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from walk(v, f"{prefix}/{i}")


def vaulted_values():
    """Yield (item name, source file, ciphertext), sorted by file."""
    files = sorted(p for p in INVENTORY.rglob("*.yml")
                   if p.parts[len(INVENTORY.parts)] in ("group_vars", "host_vars"))
    seen = {}
    for path in files:
        data = yaml.load(path.read_text(), Loader=Loader) or {}
        for name, cipher in walk(data, scope_of(path)):
            if name in seen:
                sys.exit(f"error: {name} defined in both {seen[name]} and {path}")
            seen[name] = path
            yield name, path, cipher


def decrypt(name: str, cipher: str) -> str:
    proc = subprocess.run(
        ["ansible-vault", "decrypt", "--output", "-", "-"],
        input=cipher, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        # ansible-vault's error text names the failure, not the plaintext
        msg = (proc.stderr.strip().splitlines() or ["no message"])[-1]
        raise RuntimeError(f"ansible-vault could not decrypt {name}: {msg}")
    value = proc.stdout
    # Single-line values: drop trailing newlines (templates `| trim` them anyway).
    # Multi-line values (keys, certs) are kept byte for byte.
    return value.rstrip("\n") if "\n" not in value.rstrip("\n") else value


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="list item names only")
    ap.add_argument("--update", nargs="*", default=[], metavar="NAME",
                    help="overwrite these items when they differ from the vault")
    args = ap.parse_args()

    values = list(vaulted_values())
    if args.dry_run:
        for name, path, cipher in values:
            note = "  (stub, would skip)" if STUB in cipher else ""
            print(f"{name}{note}")
        print(f"\n{len(values)} vaulted value(s)")
        return 0

    if not os.environ.get("ANSIBLE_VAULT_PASSWORD_FILE"):
        sys.exit("error: ANSIBLE_VAULT_PASSWORD_FILE is not set "
                 "(export ANSIBLE_VAULT_PASSWORD_FILE=infra/ansible/.vault-password)")
    if not os.environ.get("BW_SESSION"):
        sys.exit("error: no BW_SESSION; run under scripts/bw-run")

    vault = bwlib.Vault()
    counts = {}
    for name, path, cipher in values:
        if STUB in cipher:
            result = "skipped-stub"
        else:
            result = vault.sync_value(name, decrypt(name, cipher), update=name in args.update)
        counts[result] = counts.get(result, 0) + 1
        print(f"{name}: {result}")
    print("\n" + ", ".join(f"{n} {k}" for k, n in sorted(counts.items())))
    return 1 if counts.get("exists-DIFFERENT") else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (bwlib.BitwardenError, RuntimeError) as e:
        sys.exit(f"error: {e}")
    except Exception as e:  # never let a traceback print local variables
        sys.exit(f"error: unexpected {type(e).__name__}")
