#!/usr/bin/env python3
"""Push config files, commands and secrets to a bootc VM over SSH.

Called by Tofu (modules/bootc_vm, local-exec) with the spec as JSON, gzipped and
base64-encoded in $PUSH_SPEC_GZ (plain JSON in $PUSH_SPEC also works):

  {"host": "...", "vmid": 123, "user": "admin", "wait_seconds": 900,
   "files":   [{"path": "/etc/...", "mode": "0644", "content_b64": "..."},
               {"path": "/etc/...", "mode": "0644", "source": "/local/file", "sha256": "..."}],
   "run":     ["shell command run as root", ...],          # after the files
   "secrets": [{"item": "dns/tsig-tofu", "command": "..."}], # value on the command's stdin
   "run_after_secrets": ["...", ...]}

Proxmox's cloud-init only sets the admin user, key, hostname and network (no
snippets: uploading those needs SSH into the hypervisors). Everything else a VM
needs arrives here, after first boot, the same way for config and for secrets.

The VM's SSH host key is read through the Proxmox API (guest agent) and checked
strictly, so it needs PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN, which Tofu has.

Secrets come from Bitwarden through the BW_SESSION Tofu inherits from
scripts/bw-run, travel only over SSH stdin, and are never printed: output names
files, commands' first words and item names only.
"""
import base64
import gzip
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bwlib  # noqa: E402

import ssl
import tempfile
import urllib.parse
import urllib.request

# Host key verification without trust-on-first-use: the VM's own host key is read
# through the Proxmox API (QEMU guest agent file-read, authenticated with the
# token Tofu uses), and SSH then checks strictly against it. Host keys change
# whenever cloud-init starts a new instance (VM rebuilt, cloud-init data changed),
# so they're fetched for every push, never cached.
KNOWN_HOSTS = Path(tempfile.mkdtemp(prefix="push-vm-")) / "known_hosts"
# The image republishes it there (ssh-host-key-publish.path): the SELinux-confined
# guest agent can read its own log directory but not /etc/ssh.
HOST_KEY_FILE = "/var/log/qemu-ga/ssh-host-key.pub"


def log(msg: str) -> None:
    print(f"push-vm: {msg}", flush=True)


def pve(path: str) -> dict:
    endpoint = os.environ["PROXMOX_VE_ENDPOINT"].rstrip("/")
    req = urllib.request.Request(f"{endpoint}/api2/json{path}", headers={
        "Authorization": f"PVEAPIToken={os.environ['PROXMOX_VE_API_TOKEN']}"})
    ctx = ssl.create_default_context()
    if os.environ.get("PROXMOX_VE_INSECURE", "").lower() in ("1", "true", "yes"):
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        return json.load(r)["data"]


def host_key(spec: dict) -> str | None:
    """The VM's ed25519 host key via the guest agent, or None if not readable yet."""
    try:
        vms = pve("/cluster/resources?type=vm")
        node = next(v["node"] for v in vms if v.get("vmid") == spec["vmid"])
        q = urllib.parse.urlencode({"file": HOST_KEY_FILE})
        key = pve(f"/nodes/{node}/qemu/{spec['vmid']}/agent/file-read?{q}")["content"].strip()
        return key if key.startswith("ssh-ed25519 ") else None
    except Exception:
        return None  # agent not up yet, VM booting, key not generated yet


def pin_host_key(spec: dict) -> bool:
    key = host_key(spec)
    if not key:
        return False
    KNOWN_HOSTS.write_text(f"{spec['host']} {' '.join(key.split()[:2])}\n")
    return True


def ssh_base(spec: dict) -> list[str]:
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS}",
            "-o", "HostKeyAlgorithms=ssh-ed25519",
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
        # Re-read the key each try: cloud-init may regenerate it early in a boot.
        if pin_host_key(spec) and subprocess.run(ssh_base(spec) + ["true"],
                                                 capture_output=True).returncode == 0:
            # cloud-init creates the user early; wait until it's done (network, keys).
            subprocess.run(ssh_base(spec) + ["sudo cloud-init status --wait >/dev/null 2>&1 || true"],
                           capture_output=True)
            return
        time.sleep(5)
    raise RuntimeError(f"no SSH to {spec['user'] if 'user' in spec else 'admin'}@{spec['host']} "
                       f"within {spec.get('wait_seconds', 900)}s")


def load_spec() -> dict:
    # modules/bootc_vm passes it gzipped + base64 (an env var holds at most 128 KiB).
    if "PUSH_SPEC_GZ" in os.environ:
        return json.loads(gzip.decompress(base64.b64decode(os.environ["PUSH_SPEC_GZ"])))
    return json.loads(os.environ["PUSH_SPEC"])


def file_content(f: dict) -> bytes:
    if f.get("source"):
        data = Path(f["source"]).read_bytes()
        # The spec carries the hash Tofu saw at plan time; a file changed since then
        # would push content the plan never showed.
        if f.get("sha256") and hashlib.sha256(data).hexdigest() != f["sha256"]:
            raise RuntimeError(f"{f['source']} changed since the plan; re-plan")
        return data
    return base64.b64decode(f["content_b64"])


def main() -> int:
    spec = load_spec()
    log(f"waiting for SSH on {spec['host']}")
    wait_for_ssh(spec)

    for f in spec.get("files", []):
        content = file_content(f)
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
    except (RuntimeError, bwlib.BitwardenError, KeyError, OSError) as e:
        sys.exit(f"push-vm: error: {e}")
    except Exception as e:  # never let a traceback print local variables
        sys.exit(f"push-vm: error: unexpected {type(e).__name__}")
