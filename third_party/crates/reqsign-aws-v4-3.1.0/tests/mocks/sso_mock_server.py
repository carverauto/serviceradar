#!/usr/bin/env python3
"""
Mock SSO Credentials Server

This server simulates the AWS SSO (IAM Identity Center) API for testing purposes.
It responds to credential requests at the /federation/credentials endpoint.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import time
from urllib.parse import urlparse, parse_qs


class SSOHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_url = urlparse(self.path)
        params = parse_qs(parsed_url.query)
        
        # Check if this is the SSO credentials endpoint
        if parsed_url.path == '/federation/credentials':
            # Verify required parameters
            if 'role_name' in params and 'account_id' in params:
                # Check for authorization header
                auth_header = self.headers.get('x-amz-sso_bearer_token')
                if auth_header != 'test-access-token-for-sso':
                    self.send_response(401)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    error = {'message': 'Unauthorized: Invalid or missing bearer token'}
                    self.wfile.write(json.dumps(error).encode())
                    return
                
                # Return mock credentials
                expiration = int((time.time() + 3600) * 1000)  # 1 hour in milliseconds
                response = {
                    'roleCredentials': {
                        'accessKeyId': 'ASIASSOEXAMPLE',
                        'secretAccessKey': 'sso/secret/key/EXAMPLE',
                        'sessionToken': 'FwoGZXIvYXdzEJv//////////wEaDEXAMPLETOKEN',
                        'expiration': expiration
                    }
                }
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())
            else:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                error = {'message': 'Bad Request: Missing required parameters'}
                self.wfile.write(json.dumps(error).encode())
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            error = {'message': 'Not Found'}
            self.wfile.write(json.dumps(error).encode())
    
    def log_message(self, format, *args):
        # Log to stdout for debugging
        print(f"SSO Mock Server: {format % args}")


if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('0.0.0.0', port), SSOHandler)
    print(f'Mock SSO server running on port {port}')
    server.serve_forever()