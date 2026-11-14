import http.server
import os
import socketserver
import sys
import time


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/slow.mp4"):
            total = 50 * 1024 * 1024
            chunk = b"x" * 8192

            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(total))
            self.end_headers()

            for _ in range(total // len(chunk)):
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                time.sleep(0.02)
            return

        super().do_GET()


os.chdir(sys.argv[1])

with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
