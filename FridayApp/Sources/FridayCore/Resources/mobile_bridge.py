"""Loopback transport for the opt-in mobile companion. AppState owns all data."""
import hmac
import json
import select
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(8)

    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path != "/v1/workspace":
            return self.send_error(404)
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), bearer):
            return self.send_error(401)
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 65536:
                return self.send_error(413)
            request = json.loads(self.rfile.read(size))
            if not isinstance(request, dict):
                return self.send_error(400)
        except (ValueError, UnicodeError):
            return self.send_error(400)
        print(json.dumps(request, separators=(",", ":")), flush=True)
        reply = sys.stdin.buffer.readline()
        if not reply:
            raise SystemExit
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


if __name__ == "__main__":
    bearer = b"Bearer " + sys.stdin.buffer.readline().strip()
    with HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler) as server:
        print(json.dumps({"action":"ready", "port":server.server_port}), flush=True)
        while True:
            ready, _, _ = select.select([server, sys.stdin.buffer], [], [])
            if sys.stdin.buffer in ready:
                break
            server.handle_request()
