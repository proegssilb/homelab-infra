#!/usr/bin/env python3
"""Promote bootc-base:canary to :stable once the canary VMs have proven it.

    bootc_promote.py IMAGE PROMETHEUS_URL [--soak-hours 24] [--dry-run]

Promotes only if:
  - at least one VM tracks the canary channel (bootc_booted_image_info{channel="canary"}),
  - every such VM booted the current :canary digest,
  - each has been up on it for --soak-hours (node_boot_time_seconds; the digest
    only changes at a boot, so boot age = time on this image),
  - each is up (up == 1) and has no firing alerts.
If :stable doesn't exist yet it is seeded from :canary (first run: nothing runs
:stable, so there's nothing to protect). Prints why it did or didn't promote.

Tags are moved with `docker buildx imagetools create` (registry login must
already be done). Exit 0 whether or not it promoted; non-zero only on errors.
"""
import argparse
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request


def digest_of(ref: str) -> str | None:
    p = subprocess.run(["docker", "buildx", "imagetools", "inspect", ref,
                        "--format", "{{json .Manifest}}"], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return json.loads(p.stdout).get("digest")


def prom(url: str, query: str) -> list:
    q = urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(f"{url.rstrip('/')}/api/v1/query?{q}", timeout=20) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"prometheus query failed: {query}")
    return body["data"]["result"]


def check(url: str, canary: str, soak_hours: float) -> list[str]:
    """Return reasons not to promote (empty = promote)."""
    reasons = []
    vms = prom(url, 'bootc_booted_image_info{channel="canary"}')
    if not vms:
        return ["no VM tracks the canary channel"]
    now = time.time()
    for v in vms:
        inst = v["metric"].get("instance", "?")
        if v["metric"].get("digest") != canary:
            reasons.append(f"{inst} runs {v['metric'].get('digest', '?')[:19]}, not the canary")
            continue
        sel = f'{{instance="{inst}"}}'
        up = prom(url, f"up{sel}")
        if not up or up[0]["value"][1] != "1":
            reasons.append(f"{inst} is down")
        boot = prom(url, f"node_boot_time_seconds{sel}")
        if not boot:
            reasons.append(f"{inst}: no boot time")
        else:
            hours = (now - float(boot[0]["value"][1])) / 3600
            if hours < soak_hours:
                reasons.append(f"{inst} on the canary for {hours:.1f} h of {soak_hours:g}")
        firing = prom(url, f'ALERTS{{alertstate="firing",instance="{inst}"}}')
        if firing:
            names = sorted({a["metric"].get("alertname", "?") for a in firing})
            reasons.append(f"{inst} has firing alerts: {', '.join(names)}")
    return reasons


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("image")
    ap.add_argument("prometheus")
    ap.add_argument("--soak-hours", type=float, default=24)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    canary = digest_of(f"{a.image}:canary")
    if not canary:
        print("promote: no :canary yet; nothing to do")
        return 0
    stable = digest_of(f"{a.image}:stable")
    if stable == canary:
        print(f"promote: :stable already is the canary ({canary[:19]})")
        return 0

    if stable is None:
        print(f"promote: no :stable yet; seeding it from :canary ({canary[:19]})")
        reasons = []
    else:
        reasons = check(a.prometheus, canary, a.soak_hours)

    if reasons:
        print("promote: not promoting :canary " + canary[:19] + ":")
        for r in reasons:
            print("  - " + r)
        return 0
    if a.dry_run:
        print(f"promote: would move :stable to {canary[:19]} (dry run)")
        return 0
    subprocess.run(["docker", "buildx", "imagetools", "create", "-t", f"{a.image}:stable",
                    f"{a.image}@{canary}"], check=True)
    print(f"promote: :stable -> {canary[:19]}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        sys.exit(f"promote: error: {type(e).__name__}: {e}")
