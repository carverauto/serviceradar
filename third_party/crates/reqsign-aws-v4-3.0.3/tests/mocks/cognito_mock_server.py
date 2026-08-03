#!/usr/bin/env python3
"""
Mock server for Amazon Cognito Identity service.

This server simulates the Cognito Identity API endpoints for testing purposes.
It responds to GetId and GetCredentialsForIdentity operations.

Usage:
    python3 cognito_mock_server.py [port]
    Default port: 8443
"""

import json
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timezone, timedelta


class CognitoMockHandler(BaseHTTPRequestHandler):
    """Handler for mock Cognito Identity requests."""
    
    def do_POST(self):
        """Handle POST requests to Cognito Identity endpoints."""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        # Get the target operation from x-amz-target header
        target = self.headers.get('x-amz-target', '')
        
        if target == 'AWSCognitoIdentityService.GetId':
            self.handle_get_id(body)
        elif target == 'AWSCognitoIdentityService.GetCredentialsForIdentity':
            self.handle_get_credentials(body)
        else:
            self.send_error(400, f"Unknown operation: {target}")
    
    def handle_get_id(self, body):
        """Handle GetId operation."""
        try:
            request = json.loads(body) if body else {}
            identity_pool_id = request.get('IdentityPoolId', '')
            logins = request.get('Logins', {})
            
            # Generate a mock identity ID
            # In real Cognito, this would be unique per identity
            if logins:
                # Authenticated identity
                identity_id = f"us-east-1:auth-{hash(str(logins)) % 1000000:09x}"
            else:
                # Unauthenticated identity
                identity_id = f"us-east-1:unauth-{int(time.time()) % 1000000:09x}"
            
            response = {
                "IdentityId": identity_id
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-amz-json-1.1')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            
        except Exception as e:
            self.send_error(400, f"Invalid request: {str(e)}")
    
    def handle_get_credentials(self, body):
        """Handle GetCredentialsForIdentity operation."""
        try:
            request = json.loads(body) if body else {}
            identity_id = request.get('IdentityId', 'unknown')
            logins = request.get('Logins', {})
            
            # Generate mock credentials
            # Expire in 1 hour from now
            expiration = int((datetime.now(timezone.utc) + timedelta(hours=1)).timestamp())
            
            # Different credentials based on auth state
            if logins or 'auth' in identity_id:
                # Authenticated credentials
                access_key = "ASIACOGNITOAUTH12345678"
                secret_key = "cognitoAuthSecretKey1234567890abcdefghij"
                session_token = "FQoGZXIvYXdzEAuth...MockSessionToken"
            else:
                # Unauthenticated credentials
                access_key = "ASIACOGNITOUNAUTH123456"
                secret_key = "cognitoUnauthSecretKey1234567890abcdefgh"
                session_token = "FQoGZXIvYXdzEUnauth...MockSessionToken"
            
            response = {
                "Credentials": {
                    "AccessKeyId": access_key,
                    "SecretKey": secret_key,
                    "SessionToken": session_token,
                    "Expiration": expiration
                },
                "IdentityId": identity_id
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-amz-json-1.1')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            
        except Exception as e:
            self.send_error(400, f"Invalid request: {str(e)}")
    
    def log_message(self, format, *args):
        """Override to provide custom logging."""
        sys.stderr.write(f"[{datetime.now().isoformat()}] {format % args}\n")


def run_server(port=8443):
    """Run the mock Cognito Identity server."""
    server_address = ('', port)
    httpd = HTTPServer(server_address, CognitoMockHandler)
    
    print(f"Starting Cognito Identity mock server on port {port}...")
    print(f"Endpoints:")
    print(f"  - GetId: POST http://localhost:{port}/")
    print(f"  - GetCredentialsForIdentity: POST http://localhost:{port}/")
    print(f"\nPress Ctrl+C to stop the server.")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    run_server(port)