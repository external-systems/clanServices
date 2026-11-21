# A dual-stack HTTP server for probes: GET / answers with the client's
# address as the server saw it, GET /big with 2 MB.
pkgs: ports:
pkgs.writeText "echo-server.py" ''
  import http.server
  import socket
  import threading


  class Handler(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
          if self.path == "/big":
              body = b"x" * 2000000
          else:
              body = (self.client_address[0] + "\n").encode()
          self.send_response(200)
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)

      def log_message(self, *args):
          pass


  class Server(http.server.ThreadingHTTPServer):
      address_family = socket.AF_INET6


  servers = [Server(("::", port), Handler) for port in [${pkgs.lib.concatMapStringsSep ", " toString ports}]]
  for server in servers[1:]:
      threading.Thread(target=server.serve_forever, daemon=True).start()
  servers[0].serve_forever()
''
