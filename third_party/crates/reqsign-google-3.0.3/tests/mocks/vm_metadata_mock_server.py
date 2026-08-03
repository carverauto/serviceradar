#!/usr/bin/env python3
"""
Mock server for Google Cloud VM Metadata Service.

This server simulates the GCP metadata service that runs on 169.254.169.254
and provides instance metadata and service account tokens.
"""

import json
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer


class MetadataHandler(BaseHTTPRequestHandler):
    """Handler for GCP metadata service requests."""

    def do_GET(self):
        """Handle GET requests to metadata endpoints."""
        # Check for required Metadata-Flavor header
        if self.headers.get("Metadata-Flavor") != "Google":
            self.send_error(
                403, "Metadata-Flavor: Google header required"
            )
            return

        # Route to appropriate handler based on path
        if self.path == "/computeMetadata/v1/instance/service-accounts/":
            self.handle_list_service_accounts()
        elif self.path == "/computeMetadata/v1/instance/service-accounts/default/":
            self.handle_default_service_account()
        elif self.path.startswith(
            "/computeMetadata/v1/instance/service-accounts/default/token"
        ):
            self.handle_token_request()
        elif self.path == "/computeMetadata/v1/instance/service-accounts/default/email":
            self.handle_email_request()
        else:
            self.send_error(404, "Not Found")

    def handle_list_service_accounts(self):
        """List available service accounts."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"default/\n")

    def handle_default_service_account(self):
        """Get default service account info."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        response = "aliases\nemail\nidentity\nscopes\ntoken\n"
        self.wfile.write(response.encode())

    def handle_email_request(self):
        """Return the service account email."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        email = "test-vm-sa@test-project.iam.gserviceaccount.com"
        self.wfile.write(email.encode())

    def handle_token_request(self):
        """Generate and return an access token."""
        # Parse query parameters for scopes
        scopes = None
        if "?" in self.path:
            query_string = self.path.split("?")[1]
            for param in query_string.split("&"):
                if param.startswith("scopes="):
                    scopes = param.split("=")[1]

        # Generate token response
        expires_in = 3600
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
        
        token_response = {
            "access_token": f"mock-vm-metadata-token-{int(time.time())}",
            "expires_in": expires_in,
            "token_type": "Bearer",
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(token_response).encode())

    def log_message(self, format, *args):
        """Override to provide custom logging format."""
        sys.stderr.write(
            f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {format % args}\n"
        )


def run_server(port=8080):
    """Run the mock metadata server."""
    server_address = ("127.0.0.1", port)
    httpd = HTTPServer(server_address, MetadataHandler)
    print(f"Mock GCP Metadata Server running on http://127.0.0.1:{port}")
    print("Press Ctrl+C to stop")
    print("")
    print("Test with:")
    print(f"  curl -H 'Metadata-Flavor: Google' http://127.0.0.1:{port}/computeMetadata/v1/instance/service-accounts/default/token")
    print("")
    httpd.serve_forever()


if __name__ == "__main__":
    port = 8080
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    run_server(port)