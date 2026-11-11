"""mitmproxy addon: refuse every destination that isn't a public address.

The egress proxy exists so workspaces (AI agents) can reach the internet. It
sits on egress01, which itself may reach a few lab services (Loki for its own
logs, proxy01, the apt cache), so without this a workspace could CONNECT
through it to any of them, e.g. Loki's query API.

Each server connection is checked before mitmproxy opens it: the host is
resolved here, every address must be globally routable (no RFC 1918, loopback,
link-local, CGNAT/Tailscale, ...), and the connection is then pinned to the
vetted address so a second DNS answer can't swap in a private one (DNS
rebinding). TLS is untouched: passthrough flows keep the client's SNI, and
plain HTTP keeps its Host header.

Managed by Ansible (egress_proxy role).
"""

import asyncio
import ipaddress
import logging
import socket

from mitmproxy.proxy import server_hooks


def _public(addr: str) -> bool:
    ip = ipaddress.ip_address(addr)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_global


class BlockPrivate:
    async def server_connect(self, data: server_hooks.ServerConnectionHookData) -> None:
        host, port = data.server.address
        try:
            infos = await asyncio.get_running_loop().getaddrinfo(
                host, port, type=socket.SOCK_STREAM
            )
        except OSError as e:
            data.server.error = f"egress refused: cannot resolve {host}: {e}"
            return

        addrs = list(dict.fromkeys(info[4][0] for info in infos))
        private = [a for a in addrs if not _public(a)]
        if not addrs or private:
            data.server.error = f"egress refused: {host} is not a public address ({', '.join(private or addrs)})"
            logging.warning(
                "egress refused: client %s -> %s:%s resolves to %s",
                data.client.peername[0] if data.client.peername else "?",
                host,
                port,
                ", ".join(private or addrs),
            )
            return

        # Connect to exactly the address that was checked. mitmproxy then logs
        # only that IP, so log the name here: the logging phase is about
        # learning which hosts agents need.
        logging.info(
            "egress allowed: client %s -> %s:%s (%s)",
            data.client.peername[0] if data.client.peername else "?",
            host,
            port,
            addrs[0],
        )
        data.server.address = (addrs[0], port)


addons = [BlockPrivate()]
