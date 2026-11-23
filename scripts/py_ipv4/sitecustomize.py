"""Prefer IPv4 (AF_INET) over IPv6 (AF_INET6) to avoid 135s+ stalls on networks with blackholed IPv6."""

import socket

_orig_getaddrinfo = socket.getaddrinfo


def _ipv4_first_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    results = _orig_getaddrinfo(host, port, family, type, proto, flags)
    if family in (0, getattr(socket, "AF_UNSPEC", 0)):
        results = sorted(results, key=lambda item: 0 if item[0] == socket.AF_INET else 1)
    return results


socket.getaddrinfo = _ipv4_first_getaddrinfo
