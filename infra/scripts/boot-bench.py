#!/usr/bin/env python3
"""Time Proxmox `start` -> service answering, on the persistent bench VM.

Day-2 benchmark: the VM already exists (`just cluster-up bench`); each run
shuts it down, then times a fresh start through three phases:

  api      start task (UPID) reports OK          -- Proxmox API time
  agent    guest agent reports an eth0 IPv4      -- firmware + kernel + early userspace
  service  http://<ip>:<port>/ returns 200       -- everything up to the container

total = t0 (just before the start POST) -> service. Phases are cumulative
offsets from t0. Uses PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN, same as tofu.
After the last run, ssh in once for systemd-analyze to show where guest time went.

--docker skips the VM reboot and times docker alone on the already-running VM:

  container  `docker compose start` (daemon already up)   -> service 200
  daemon     `systemctl start docker` (container returns via its restart policy)
             phases: daemon = start command returns, service = HTTP 200

Each run stops the thing under test first (untimed). One multiplexed ssh
connection is reused so handshake time stays out of the numbers.
"""
import argparse
import json
import os
import ssl
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

POLL = 0.25
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # matches validate_certs: false in the inventory


def api(method, path, **form):
    base = os.environ["PROXMOX_VE_ENDPOINT"].rstrip("/")
    data = urllib.parse.urlencode(form).encode() if form else None
    req = urllib.request.Request(
        f"{base}/api2/json{path}", data=data, method=method,
        headers={"Authorization": f"PVEAPIToken={os.environ['PROXMOX_VE_API_TOKEN']}"},
    )
    with urllib.request.urlopen(req, context=CTX, timeout=15) as r:
        return json.load(r)["data"]


def wait_task(node, upid, deadline):
    while time.monotonic() < deadline:
        t = api("GET", f"/nodes/{node}/tasks/{urllib.parse.quote(upid)}/status")
        if t["status"] == "stopped":
            if t.get("exitstatus") != "OK":
                raise RuntimeError(f"task failed: {t.get('exitstatus')}")
            return
        time.sleep(POLL)
    raise TimeoutError("start task did not finish")


def ensure_stopped(node, vmid):
    vm = f"/nodes/{node}/qemu/{vmid}"
    if api("GET", f"{vm}/status/current")["status"] == "running":
        api("POST", f"{vm}/status/shutdown", forceStop=1, timeout=60)
    deadline = time.monotonic() + 120
    while api("GET", f"{vm}/status/current")["status"] != "stopped":
        if time.monotonic() > deadline:
            raise TimeoutError("VM did not stop")
        time.sleep(1)


def guest_ip(node, vmid):
    try:
        res = api("GET", f"/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces")["result"]
    except urllib.error.HTTPError:
        return None  # agent not up yet
    for nic in res:
        if nic["name"] == "eth0":
            for a in nic.get("ip-addresses", []):
                if a["ip-address-type"] == "ipv4":
                    return a["ip-address"]
    return None


def http_ok(ip, port):
    try:
        with urllib.request.urlopen(f"http://{ip}:{port}/", timeout=2) as r:
            return r.status == 200
    except (OSError, urllib.error.URLError):
        return False


def one_run(node, vmid, port, timeout):
    ensure_stopped(node, vmid)
    vm = f"/nodes/{node}/qemu/{vmid}"
    t0 = time.monotonic()
    deadline = t0 + timeout
    upid = api("POST", f"{vm}/status/start")
    wait_task(node, upid, deadline)
    t_api = time.monotonic() - t0
    ip = None
    while not ip:
        if time.monotonic() > deadline:
            raise TimeoutError("guest agent never reported an IP")
        ip = guest_ip(node, vmid) or time.sleep(POLL)
    t_agent = time.monotonic() - t0
    while not http_ok(ip, port):
        if time.monotonic() > deadline:
            raise TimeoutError(f"{ip}:{port} never answered")
        time.sleep(POLL)
    return (t_api, t_agent, time.monotonic() - t0), ip


def ssh_cmd(ip, user):
    return ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=60",
            "-o", f"ControlPath=/tmp/boot-bench-{os.getpid()}.sock", f"{user}@{ip}"]


COMPOSE = "sudo docker compose -f /opt/ittools/docker-compose.yml"
STACK_UP = f"sudo systemctl reset-failed docker docker.socket; sudo systemctl start docker && {COMPOSE} start"
DOCKER_SCENARIOS = {
    # name: (untimed prep, timed command). reset-failed clears docker.service's
    # start-rate limit, which would otherwise refuse the 4th start inside 60s.
    "container": (f"{COMPOSE} stop", f"{COMPOSE} start"),
    "daemon": ("sudo systemctl stop docker docker.socket && sudo systemctl reset-failed docker docker.socket", "sudo systemctl start docker"),
}


def docker_run(ssh, ip, port, scenario, timeout):
    prep, timed = DOCKER_SCENARIOS[scenario]
    subprocess.run(ssh + [prep], check=True, capture_output=True)
    t0 = time.monotonic()
    deadline = t0 + timeout
    subprocess.run(ssh + [timed], check=True, capture_output=True, timeout=timeout)
    t_cmd = time.monotonic() - t0
    while not http_ok(ip, port):
        if time.monotonic() > deadline:
            raise TimeoutError(f"{ip}:{port} never answered")
        time.sleep(0.05)
    return t_cmd, time.monotonic() - t0


def docker_bench(a, node, vmid):
    ip = guest_ip(node, vmid)
    if not ip:
        sys.exit(f"{a.vm} is not running (or has no agent); start it first")
    ssh = ssh_cmd(ip, a.user)
    subprocess.run(ssh + [STACK_UP], check=True, capture_output=True)  # also opens the shared connection
    print(f"{a.vm} ({ip}), docker only, {a.runs} runs each, seconds from command start")
    try:
        for scenario in DOCKER_SCENARIOS:
            print(f"\n[{scenario}]  {'run':>3} {'cmd':>7} {'service':>8}")
            rows = []
            for i in range(1, a.runs + 1):
                try:
                    r = docker_run(ssh, ip, a.port, scenario, a.timeout)
                except (TimeoutError, subprocess.SubprocessError) as e:
                    print(f"{'':>11}{i:>3} FAILED: {e}")
                    continue
                rows.append(r)
                print(f"{'':>11}{i:>3} {r[0]:7.2f} {r[1]:8.2f}")
            if rows:
                for label, fn in (("min", min), ("median", statistics.median), ("max", max)):
                    print(f"{'':>11}{label:<4} " + "".join(f"{fn(c):8.2f}" for c in zip(*rows)))
    finally:
        # Leave the VM as we found it: stack up.
        subprocess.run(ssh + [STACK_UP], check=False, capture_output=True)
        subprocess.run(ssh + ["-O", "exit"], check=False, capture_output=True)


def analyze(ip, user):
    ssh = ssh_cmd(ip, user)
    # The container can answer before systemd has finished every job.
    subprocess.run(ssh + ["systemctl is-system-running --wait >/dev/null"], check=False)
    for cmd in ("systemd-analyze", "systemd-analyze critical-chain --no-pager",
                "systemd-analyze blame --no-pager | head -15"):
        print(f"\n$ {cmd}", flush=True)
        subprocess.run(ssh + [cmd], check=False)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--runs", type=int, default=5)
    p.add_argument("--vm", default="bench01")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--timeout", type=int, default=180, help="per-run seconds")
    p.add_argument("--user", default="ansible")
    p.add_argument("--docker", action="store_true",
                   help="time docker alone on the running VM instead of a VM start")
    a = p.parse_args()

    out = subprocess.run(["tofu", "-chdir=tofu/bench", "output", "-json", "vms"],
                         capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"tofu output failed (run `just cluster-up bench` first):\n{out.stderr}")
    vms = json.loads(out.stdout)
    if a.vm not in vms:
        sys.exit(f"{a.vm} not in tofu/bench outputs: {sorted(vms)}")
    node, vmid = vms[a.vm]["node"], vms[a.vm]["vmid"]
    if a.docker:
        return docker_bench(a, node, vmid)

    print(f"{a.vm} (vmid {vmid} on {node}), {a.runs} runs, offsets from start request, seconds")
    print(f"{'run':>3} {'api':>7} {'agent':>7} {'service':>8}")
    rows, ip = [], None
    for i in range(1, a.runs + 1):
        try:
            r, ip = one_run(node, vmid, a.port, a.timeout)
        except (TimeoutError, RuntimeError, OSError) as e:
            print(f"{i:>3} FAILED: {e}")
            continue
        rows.append(r)
        print(f"{i:>3} {r[0]:7.2f} {r[1]:7.2f} {r[2]:8.2f}")

    if not rows:
        sys.exit("all runs failed")
    print("\n      " + "".join(f"{n:>9}" for n in ("api", "agent", "service")))
    for label, fn in (("min", min), ("median", statistics.median), ("max", max)):
        print(f"{label:<6}" + "".join(f"{fn(c):9.2f}" for c in zip(*rows)))
    if len(rows) < a.runs:
        print(f"\n{a.runs - len(rows)} run(s) failed; stats cover {len(rows)}")
    analyze(ip, a.user)


if __name__ == "__main__":
    main()
