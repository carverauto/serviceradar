#!/usr/bin/env python3
"""
Mock credential process helper for testing ProcessCredentialProvider

This script outputs credentials in the format expected by AWS credential_process.
It can be used in ~/.aws/config as:
    credential_process = /path/to/credential_process_helper.py
"""

import json
import sys
from datetime import datetime, timedelta


def generate_credentials(profile=None):
    """Generate mock AWS credentials in the credential_process format"""
    
    # Calculate expiration time (1 hour from now)
    expiration = (datetime.utcnow() + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    # Different credentials based on profile (for testing multiple profiles)
    if profile == "test":
        access_key = "ASIAPROCESSTEST"
        secret_key = "process/test/secret/key/EXAMPLE"
    else:
        access_key = "ASIAPROCESSEXAMPLE"
        secret_key = "process/secret/key/EXAMPLE"
    
    credentials = {
        "Version": 1,
        "AccessKeyId": access_key,
        "SecretAccessKey": secret_key,
        "SessionToken": "FwoGZXIvYXdzEPROCESS//////////wEaDEXAMPLETOKEN",
        "Expiration": expiration
    }
    
    return credentials


def main():
    """Main entry point for the credential process helper"""
    
    # Check if a profile argument was provided
    profile = None
    if len(sys.argv) > 2 and sys.argv[1] == "--profile":
        profile = sys.argv[2]
    
    # Generate and output credentials
    credentials = generate_credentials(profile)
    print(json.dumps(credentials, indent=2))
    
    return 0


if __name__ == "__main__":
    sys.exit(main())