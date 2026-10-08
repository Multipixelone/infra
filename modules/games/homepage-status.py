"""Expose only registry-listed loopback TCP reachability to Homepage."""

import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tcp_status(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return "Up"
    except OSError:
        return "Down"


def make_server(ports, port=18777):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            server_id = self.path.removeprefix("/servers/")
            if self.path != f"/servers/{server_id}" or server_id not in ports:
                self.send_error(404)
                return
            body = json.dumps({"status": tcp_status(ports[server_id])}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    with open(sys.argv[1]) as inventory:
        ports = json.load(inventory)
    with make_server(ports) as server:
        server.serve_forever()
