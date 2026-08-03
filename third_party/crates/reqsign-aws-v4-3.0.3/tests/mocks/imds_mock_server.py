#!/usr/bin/env python3
"""
Mock EC2 IMDS (Instance Metadata Service) Server

This server simulates the EC2 Instance Metadata Service for testing purposes.
It implements IMDSv2 protocol with token-based authentication.
"""

import json
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime, timedelta


class IMDSHandler(BaseHTTPRequestHandler):
    # Static token for simplicity in testing
    MOCK_TOKEN = "mock-imdsv2-token"
    
    def do_PUT(self):
        """Handle IMDSv2 token requests"""
        if self.path == '/latest/api/token':
            # Check TTL header
            ttl_header = self.headers.get('x-aws-ec2-metadata-token-ttl-seconds')
            if not ttl_header:
                self.send_response(400)
                self.end_headers()
                return
            
            # Return mock token
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('x-aws-ec2-metadata-token-ttl-seconds', ttl_header)
            self.end_headers()
            self.wfile.write(self.MOCK_TOKEN.encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_GET(self):
        """Handle metadata requests"""
        # Check for IMDSv2 token
        token = self.headers.get('x-aws-ec2-metadata-token')
        if token != self.MOCK_TOKEN:
            # IMDSv2 requires token
            self.send_response(401)
            self.end_headers()
            return
        
        if self.path == '/latest/meta-data/iam/security-credentials/':
            # Return role name
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'test-imds-role')
        elif self.path == '/latest/meta-data/iam/security-credentials/test-imds-role':
            # Return credentials
            expiration = (datetime.utcnow() + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
            response = {
                'Code': 'Success',
                'LastUpdated': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                'Type': 'AWS-HMAC',
                'AccessKeyId': 'AKIAIMDSEXAMPLE',
                'SecretAccessKey': 'imds/secret/key/EXAMPLE',
                'Token': 'IQoJb3JpZ2luX2VjIMDS//////////wEaCXVzLXdlc3QtMiJGMEQCIDyJl0YXIMDS',
                'Expiration': expiration
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Log to stdout for debugging
        print(f"IMDS Mock Server: {format % args}")


if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 1338
    server = HTTPServer(('0.0.0.0', port), IMDSHandler)
    print(f'Mock IMDS server running on port {port}')
    server.serve_forever()