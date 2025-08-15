#!/bin/sh
echo "Fixing certificate permissions..."

# Fix permissions for ServiceRadar components (user 1000)
chown -R 1000:1000 /etc/serviceradar/certs/
chmod 755 /etc/serviceradar/certs/
chmod 644 /etc/serviceradar/certs/*.pem
chmod 644 /etc/serviceradar/certs/*-key.pem  # Make private keys readable by owner and group

# Make certificates readable by group (for Proton which runs as uid=999, gid=999)  
chgrp -R 1000 /etc/serviceradar/certs/
chmod g+r /etc/serviceradar/certs/*.pem
chmod g+r /etc/serviceradar/certs/*-key.pem

echo "✅ Certificate permissions fixed for ServiceRadar components (1000:1000)"