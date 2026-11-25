"""Small Bitwarden CLI wrapper shared by the secret scripts.

Values only ever travel through subprocess pipes: items are created and edited
by feeding base64 JSON to `bw` on stdin (never argv, which any local process
can read from /proc), and nothing here prints or logs a value. Callers must
keep it that way: report item *names* only.

Needs BW_SESSION in the environment, which `scripts/bw-run` provides.
"""

import base64
import json
import os
import shutil
import subprocess

FOLDER = "homelab"


class BitwardenError(Exception):
    """A bw call failed. The message never contains a value."""


def bw_path() -> str:
    path = shutil.which("bw")
    if not path:
        raise BitwardenError("bw CLI not found (install: brew install bitwarden-cli)")
    return path


def _run(args, stdin: str | None = None, env: dict | None = None) -> str:
    proc = subprocess.run(
        [bw_path(), *args],
        input=stdin,
        capture_output=True,
        text=True,
        env=env if env is not None else os.environ,
    )
    if proc.returncode != 0:
        # bw's stderr describes the failure, not the payload, but keep it short
        # and drop anything after a newline to be safe.
        first = (proc.stderr or "").strip().splitlines()[:1]
        raise BitwardenError(f"bw {args[0]} failed: {first[0] if first else 'no message'}")
    return proc.stdout


def _encode(obj: dict) -> str:
    return base64.b64encode(json.dumps(obj).encode()).decode()


def status(env: dict | None = None) -> str:
    """Return 'unauthenticated', 'locked' or 'unlocked'."""
    return json.loads(_run(["status"], env=env))["status"]


class Vault:
    """Items in the `homelab` folder, fetched once and indexed by exact name."""

    def __init__(self):
        self.folder_id = self._folder_id()
        self._items = None

    def _folder_id(self) -> str:
        folders = json.loads(_run(["list", "folders", "--search", FOLDER]))
        for f in folders:
            if f["name"] == FOLDER:
                return f["id"]
        created = json.loads(_run(["create", "folder"], stdin=_encode({"name": FOLDER})))
        return created["id"]

    @property
    def items(self) -> dict:
        if self._items is None:
            listed = json.loads(_run(["list", "items", "--folderid", self.folder_id]))
            self._items = {}
            for it in listed:
                if it["name"] in self._items:
                    raise BitwardenError(f"two items named {it['name']!r} in folder {FOLDER}")
                self._items[it["name"]] = it
        return self._items

    def exists(self, name: str) -> bool:
        return name in self.items

    def get(self, name: str) -> str:
        it = self.items.get(name)
        if it is None:
            raise BitwardenError(f"no item named {name!r} in folder {FOLDER}")
        login = it.get("login") or {}
        if login.get("password"):
            return login["password"]
        if it.get("notes"):
            return it["notes"]
        raise BitwardenError(f"item {name!r} has neither a password nor notes")

    @staticmethod
    def _shape(value: str) -> tuple[str | None, str | None]:
        """(password, notes): single-line values in password, multi-line in notes."""
        return (None, value) if "\n" in value.rstrip("\n") else (value, None)

    def create(self, name: str, value: str) -> None:
        password, notes = self._shape(value)
        item = {
            "organizationId": None,
            "folderId": self.folder_id,
            "type": 1,
            "name": name,
            "notes": notes,
            "favorite": False,
            "fields": [],
            "login": {"uris": [], "username": None, "password": password, "totp": None},
            "reprompt": 0,
        }
        created = json.loads(_run(["create", "item"], stdin=_encode(item)))
        self.items[name] = created

    def delete(self, name: str) -> None:
        """Move an item to Bitwarden's trash (recoverable there for 30 days)."""
        it = self.items.get(name)
        if it is None:
            raise BitwardenError(f"no item named {name!r} in folder {FOLDER}")
        _run(["delete", "item", it["id"]])
        del self.items[name]

    def update(self, name: str, value: str) -> None:
        it = dict(self.items[name])
        password, notes = self._shape(value)
        it["notes"] = notes
        it["login"] = dict(it.get("login") or {}, password=password)
        updated = json.loads(_run(["edit", "item", it["id"]], stdin=_encode(it)))
        self.items[name] = updated

    def sync_value(self, name: str, value: str, update: bool = False) -> str:
        """Create if missing; never overwrite unless update=True. Returns a status word."""
        if not self.exists(name):
            self.create(name, value)
            return "created"
        if self.get(name) == value:
            return "exists-same"
        if update:
            self.update(name, value)
            return "updated"
        return "exists-DIFFERENT"
