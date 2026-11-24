#!/usr/bin/env python3
"""Copy Tofu's secrets from .env and terraform.tfvars into Bitwarden.

    scripts/bw-run -- scripts/secrets-to-bitwarden.py [--dry-run] [--update NAME ...]
    scripts/secrets-to-bitwarden.py --check

Sources, all read by this script only (never shown to a person or an agent):
  - the repo-root .env: the keys that secrets.env.map maps to `env/<NAME>` items
  - tofu/<state>/terraform.tfvars: variables declared `sensitive = true` in that
    state's variables.tf, stored as `<state>/<var>`. Non-string values (lists,
    maps, numbers) are stored as JSON, which Tofu accepts in TF_VAR_<name>.

Prints names and a status word only. Values go to `bw` on stdin. Errors name the
file, variable and line, never content. Files are not modified: once `just plan`
passes through Bitwarden, delete the copied keys by hand, then run --check.

--check reports, by name, every mapped .env key and sensitive tfvars variable
still present in those files (exit 1 if any), plus tfvars names that look like
secrets but are not declared sensitive.
"""

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bwlib  # noqa: E402
import hcl_literals as hcl  # noqa: E402

INFRA = Path(__file__).resolve().parent.parent   # where secrets.env.map lives
# Where .env and the tfvars live; --root overrides (e.g. the main checkout when
# this runs from a git worktree, which has no gitignored files).
FILES = INFRA
STATES = ("platform", "pets", "bench")
LOOKS_SECRET = re.compile(r"pass|secret|token|private|api_?key|credential", re.I)


def env_map() -> dict[str, str]:
    out = {}
    for line in (INFRA / "secrets.env.map").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            k, v = (s.strip() for s in line.split("=", 1))
            out[k] = v
    return out


def dotenv_values(path: Path) -> dict[str, str]:
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        val = m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        elif " #" in val:
            val = val.split(" #", 1)[0].rstrip()
        out[m.group(1)] = val
    return out


def gather(report):
    """Yield (item name, value) for every secret found; report(name, status) for problems."""
    wanted = {item[len("env/"):] for item in env_map().values() if item.startswith("env/")}
    found = dotenv_values(FILES.parent / ".env")
    for key in sorted(wanted):
        if key in found:
            yield f"env/{key}", found[key]
        else:
            report(f"env/{key}", "not-in-.env")

    for state in STATES:
        tfvars = FILES / "tofu" / state / "terraform.tfvars"
        variables = FILES / "tofu" / state / "variables.tf"
        if not tfvars.exists() or not variables.exists():
            continue
        sensitive = hcl.sensitive_variables(variables.read_text())
        try:
            for name, value in hcl.parse(tfvars.read_text()):
                if name in sensitive:
                    yield f"{state}/{name}", hcl.to_env(value)
        except hcl.HclError as e:
            var = getattr(e, "var", None) or "?"
            kind = "unsupported-syntax (move by hand)" if isinstance(e, hcl.Unsupported) \
                else f"parse error at line {e.line}; later variables in this file not read"
            report(f"{state}/{var}", kind)


def check() -> int:
    present = [p for p in [FILES.parent / ".env"]
               + [FILES / "tofu" / s / "terraform.tfvars" for s in STATES] if p.exists()]
    if not present:
        # A git worktree has no gitignored files: "clean" here would be a lie.
        print(f"error: no .env or terraform.tfvars found under {FILES} "
              f"(in a worktree? pass --root <main checkout>/infra)")
        return 2
    leftovers = 0
    mapped = {item[len("env/"):] for item in env_map().values() if item.startswith("env/")}
    for key in sorted(mapped & dotenv_values(FILES.parent / ".env").keys()):
        print(f".env: {key} still present")
        leftovers += 1
    for state in STATES:
        tfvars = FILES / "tofu" / state / "terraform.tfvars"
        variables = FILES / "tofu" / state / "variables.tf"
        if not tfvars.exists() or not variables.exists():
            continue
        sensitive = hcl.sensitive_variables(variables.read_text())
        names = [n for n, _ in hcl.parse(tfvars.read_text())]
        for n in names:
            if n in sensitive:
                print(f"tofu/{state}/terraform.tfvars: {n} still present")
                leftovers += 1
            elif LOOKS_SECRET.search(n):
                print(f"tofu/{state}/terraform.tfvars: {n} looks secret but isn't "
                      f"declared sensitive (review)")
    print("clean" if not leftovers else f"{leftovers} secret(s) still in files")
    return 1 if leftovers else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="list names, no Bitwarden writes")
    ap.add_argument("--check", action="store_true", help="report secrets still left in files")
    ap.add_argument("--update", nargs="*", default=[], metavar="NAME")
    ap.add_argument("--root", type=Path, metavar="INFRA_DIR",
                    help="infra/ dir holding the gitignored tfvars (its parent holds .env)")
    args = ap.parse_args()
    global FILES
    if args.root:
        FILES = args.root.resolve()

    if args.check:
        return check()

    problems = []

    def report(name, status):
        problems.append(name)
        print(f"{name}: {status}")

    secrets = list(gather(report))
    if args.dry_run:
        for name, _ in secrets:
            print(f"{name}: would copy")
        print(f"\n{len(secrets)} to copy, {len(problems)} problem(s)")
        return 1 if problems else 0

    if not os.environ.get("BW_SESSION"):
        sys.exit("error: no BW_SESSION; run under scripts/bw-run")
    vault = bwlib.Vault()
    different = 0
    for name, value in secrets:
        result = vault.sync_value(name, value, update=name in args.update)
        different += result == "exists-DIFFERENT"
        print(f"{name}: {result}")
    mapped_items = set(env_map().values())
    for name, _ in secrets:
        if name not in mapped_items:
            print(f"note: {name} is not in secrets.env.map yet "
                  f"(add TF_VAR_{name.split('/', 1)[1]}={name})")
    return 1 if (problems or different) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except bwlib.BitwardenError as e:
        sys.exit(f"error: {e}")
    except hcl.HclError as e:
        sys.exit(f"error: tfvars {getattr(e, 'var', '?')}: line {e.line}")
    except Exception as e:  # never let a traceback print local variables
        sys.exit(f"error: unexpected {type(e).__name__}")
