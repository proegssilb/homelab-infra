"""mitmproxy addon: check each destination host against an allowlist.

Two modes (option egress_allowlist_mode):
  shadow   pass everything, but log whether the host is on the list:
           "egress listed: ..." or "egress would refuse: ...". Lets the list
           be tuned on real use before it blocks anything.
  enforce  refuse hosts not on the list ("egress refused: ... not on the
           allowlist").

The list (option egress_allowlist) is a file, one entry per line, "#"
comments allowed:
  example.com     that host only
  *.example.com   any subdomain of example.com (not example.com itself)
IP-literal destinations never match.

Must load before block_private.py: that addon rewrites the server address to
the vetted IP, after which the hostname is gone. Non-public destinations are
refused by block_private.py regardless of this list.

Managed by Ansible (egress_proxy role).
"""

import logging

from mitmproxy import ctx
from mitmproxy.proxy import server_hooks


def _norm(host: str) -> str:
    return host.strip().rstrip(".").lower()


class Allowlist:
    def __init__(self) -> None:
        self.exact: set[str] = set()
        self.suffixes: tuple[str, ...] = ()

    def load(self, loader) -> None:
        loader.add_option(
            "egress_allowlist", str, "", "File with allowed destination hosts."
        )
        loader.add_option(
            "egress_allowlist_mode",
            str,
            "shadow",
            "shadow: log only; enforce: refuse hosts not on the list.",
        )

    def configure(self, updated) -> None:
        if "egress_allowlist_mode" in updated and ctx.options.egress_allowlist_mode not in (
            "shadow",
            "enforce",
        ):
            raise ValueError("egress_allowlist_mode must be shadow or enforce")
        if "egress_allowlist" in updated:
            exact, suffixes = set(), set()
            path = ctx.options.egress_allowlist
            if path:
                with open(path) as f:
                    for line in f:
                        entry = _norm(line.split("#", 1)[0])
                        if not entry:
                            continue
                        if entry.startswith("*."):
                            suffixes.add(entry[1:])  # ".example.com"
                        else:
                            exact.add(entry)
            self.exact, self.suffixes = exact, tuple(sorted(suffixes))
            logging.info(
                "egress allowlist: %d hosts, %d wildcard domains, mode %s",
                len(exact),
                len(suffixes),
                ctx.options.egress_allowlist_mode,
            )

    def listed(self, host: str) -> bool:
        host = _norm(host)
        return host in self.exact or host.endswith(self.suffixes)

    def server_connect(self, data: server_hooks.ServerConnectionHookData) -> None:
        host, port = data.server.address
        client = data.client.peername[0] if data.client.peername else "?"
        if self.listed(host):
            logging.info("egress listed: client %s -> %s:%s", client, host, port)
            return
        if ctx.options.egress_allowlist_mode == "enforce":
            data.server.error = f"egress refused: {host} is not on the allowlist"
            logging.warning("egress refused: client %s -> %s:%s not on the allowlist", client, host, port)
        else:
            logging.warning("egress would refuse: client %s -> %s:%s not on the allowlist", client, host, port)


addons = [Allowlist()]
