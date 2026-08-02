#!/usr/bin/env python3
"""
Mock ECS Credentials Server

This server simulates the ECS Task IAM Roles endpoint for testing purposes.
It responds to credential requests at the /creds endpoint.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
from datetime import datetime, timedelta


class ECSHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/creds':
            # Return mock credentials
            last_updated = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
            expiration = (datetime.utcnow() + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
            response = {
                'RoleArn': 'arn:aws:iam::123456789012:role/test-ecs-role',
                'Type': 'AWS-HMAC',
                'AccessKeyId': 'AKIAIOSFODNN7EXAMPLE',
                'SecretAccessKey': 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
                'Token': 'IQoJb3JpZ2luX2VjEJv//////////wEaCXVzLXdlc3QtMiJGMEQCIDyJl0YXJwU8iBG4gLVxiNJTYfLp3oFxEOpGGHmQuWmFAiBHEK/GkClQFb0aQ/+kOZkzHKVAPItVJW/VEXAMPLE=',
                'Expiration': expiration,
                'LastUpdated': last_updated,
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress logs to stderr
        pass


if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 51679
    server = HTTPServer(('0.0.0.0', port), ECSHandler)
    print(f'Mock ECS server running on port {port}')
    server.serve_forever()
