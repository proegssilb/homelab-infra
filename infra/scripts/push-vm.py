#!/usr/bin/env python3
"""Push config files, commands and secrets to a bootc VM over SSH.

Called by Tofu (modules/bootc_vm, local-exec) with the spec as JSON in $PUSH_SPEC:

  {"host": "...", "user": "admin", "wait_seconds": 900,
   "files":   [{"path": "/etc/...", "mode": "0644", "content_b64": "..."}],
   "run":     ["shell command run as root", ...],          # after the files
   "secrets": [{"item": "dns/tsig-tofu", "command": "..."}], # value on the command's stdin
   "run_after_secrets": ["...", ...]}

Proxmox's cloud-init only sets the admin user, key, hostname and network (no
snippets: uploading those needs SSH into the hypervisors). Everything else a VM
needs arrives here, after first boot, the same way for config and for secrets.

Secrets come from Bitwarden through the BW_SESSION Tofu inherits from
scripts/bw-run, travel only over SSH stdin, and are never printed: output names
files, commands' first words and item names only.
"""
import base64
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bwlib  # noqa: E402

KNOWN_HOSTS = Path.home() / ".cache" / "homelab-push" / "known_hosts"


def log(msg: str) -> None:
    print(f"push-vm: {msg}", flush=True)


def ssh_base(spec: dict) -> list[str]:
    KNOWN_HOSTS.parent.mkdir(parents=True, exist_ok=True)
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
            f"{spec.get('user', 'admin')}@{spec['host']}"]


def remote(spec: dict, command: str, stdin: bytes | None = None, what: str = "") -> None:
    proc = subprocess.run(ssh_base(spec) + ["sudo sh -c " + shlex.quote(command)],
                          input=stdin, capture_output=True)
    if proc.returncode != 0:
        # stderr of a config command is safe to show; a secret command's is not
        # (it might echo input), so callers pass what="secret" to suppress it.
        detail = "" if what == "secret" else ": " + proc.stderr.decode(errors="replace").strip()[-400:]
        raise RuntimeError(f"remote command failed ({command.split()[0]}){detail}")


def wait_for_ssh(spec: dict) -> None:
    deadline = time.monotonic() + int(spec.get("wait_seconds", 900))
    while time.monotonic() < deadline:
        if subprocess.run(ssh_base(spec) + ["true"], capture_output=True).returncode == 0:
            # cloud-init creates the user early; wait until it's done (network, keys).
            subprocess.run(ssh_base(spec) + ["sudo cloud-init status --wait >/dev/null 2>&1 || true"],
                           capture_output=True)
            return
        time.sleep(5)
    raise RuntimeError(f"no SSH to {spec['user'] if 'user' in spec else 'admin'}@{spec['host']} "
                       f"within {spec.get('wait_seconds', 900)}s")


def main() -> int:
    spec = json.loads(os.environ["PUSH_SPEC"])
    log(f"waiting for SSH on {spec['host']}")
    wait_for_ssh(spec)

    for f in spec.get("files", []):
        content = base64.b64decode(f["content_b64"])
        remote(spec, f"install -D -m {shlex.quote(f.get('mode', '0644'))} /dev/stdin "
                     f"{shlex.quote(f['path'])}", stdin=content)
        log(f"file {f['path']}")

    for cmd in spec.get("run", []):
        remote(spec, cmd)
        log(f"ran {cmd.split()[0]}")

    secrets = spec.get("secrets", [])
    if secrets:
        if not os.environ.get("BW_SESSION"):
            raise RuntimeError("secrets to push but no BW_SESSION (run tofu through scripts/bw-run)")
        vault = bwlib.Vault()
        for s in secrets:
            remote(spec, s["command"], stdin=vault.get(s["item"]).encode(), what="secret")
            log(f"secret {s['item']}")

    for cmd in spec.get("run_after_secrets", []):
        remote(spec, cmd)
        log(f"ran {cmd.split()[0]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, bwlib.BitwardenError, KeyError) as e:
        sys.exit(f"push-vm: error: {e}")
    except Exception as e:  # never let a traceback print local variables
        sys.exit(f"push-vm: error: unexpected {type(e).__name__}")
