#!/usr/bin/env python3
"""
Minimal IMDS mock server for testing
"""
import json
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

class IMDSHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        
        # Check Metadata header
        if self.headers.get('Metadata') != 'true':
            self.send_error(400, "Metadata header required")
            return
        
        if parsed.path == '/metadata/identity/oauth2/token':
            api_version = query.get('api-version', [''])[0]
            if api_version not in ('2018-02-01', '2019-08-01'):
                self.send_error(400, "unsupported api-version")
                return

            resource = query.get('resource', [''])[0]
            if not resource:
                self.send_error(400, "resource query required")
                return

            # Mock token response
            token_response = {
                "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6IjJaUXBKTTBWYmJQWGhzMWpvT1ljYjh0WXhPXyIsImtpZCI6IjJaUXBKTTBWYmJQWGhzMWpvT1ljYjh0WXhPXyJ9.eyJhdWQiOiJodHRwczovL3N0b3JhZ2UuYXp1cmUuY29tLyIsImlzcyI6Imh0dHBzOi8vc3RzLndpbmRvd3MubmV0LzEyMzQ1Njc4LTEyMzQtMTIzNC0xMjM0LTEyMzQ1Njc4OTAxMi8iLCJpYXQiOjE2MzM1MzY0MjIsIm5iZiI6MTYzMzUzNjQyMiwiZXhwIjoxNjMzNjIzMTIyLCJhaW8iOiJFMlpnWUxqL3Y3Ly9kWitQL0JBQSIsImFwcGlkIjoiMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5MDEyIiwiYXBwaWRhY3IiOiIyIiwiaWRwIjoiaHR0cHM6Ly9zdHMud2luZG93cy5uZXQvMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5MDEyLyIsIm9pZCI6IjEyMzQ1Njc4LTEyMzQtMTIzNC0xMjM0LTEyMzQ1Njc4OTAxMiIsInJoIjoiMC5BUm9BZUhZME5HRHlORWFTVGh0bUZZaVNFZ2dBQUFBQUFBQUF3QUFBQUFBQUFBQ2NBQUEuIiwic3ViIjoiMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5MDEyIiwidGlkIjoiMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5MDEyIiwidXRpIjoiMTIzNDU2NzgtMTIzNC0xMjM0LTEyMzQtMTIzNDU2Nzg5MDEyIiwidmVyIjoiMS4wIn0.mock_signature",
                "expires_in": "3600",
                "expires_on": str(int(time.time()) + 3600),
                "resource": resource,
                "token_type": "Bearer"
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(token_response).encode())
        else:
            self.send_error(404, "Not Found")
    
    def log_message(self, format, *args):
        pass  # Suppress logs

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('', port), IMDSHandler)
    print(f"IMDS mock server started on port {port}")
    server.serve_forever()
