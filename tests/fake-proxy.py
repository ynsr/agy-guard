#!/usr/bin/env python3
"""Stub HTTP proxy for the bats suite: answers every request with 204.

Plain-HTTP probes (AGY_GUARD_PROBE_URL=http://…/generate_204) reach it as an
absolute-URI GET, so no CONNECT/TLS is needed and the guard's egress check
passes without any real network access.
"""
import socket
import sys

port = int(sys.argv[1])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(32)
print("ready", flush=True)

while True:
    conn, _ = srv.accept()
    try:
        conn.recv(65535)
        conn.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
    except Exception:
        pass
    finally:
        conn.close()
