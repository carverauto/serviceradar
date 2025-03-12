#!/bin/bash

# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# package.sh for web component - Used as reference for packaging scripts
set -e

# Define package version
VERSION=${VERSION:-1.0.24}

# Create the directory structure
mkdir -p web-build
cd web-build

# Create package directory structure
mkdir -p usr/local/share/serviceradar-web
mkdir -p lib/systemd/system
mkdir -p etc/serviceradar
mkdir -p etc/nginx/conf.d

# Build Next.js application
echo "Building web application..."
cd ../web
npm install
npm run build

# Copy the Next.js standalone build
echo "Copying built web files..."
cp -r .next/standalone/* "../web-build/usr/local/share/serviceradar-web/"
cp -r .next/standalone/.next "../web-build/usr/local/share/serviceradar-web/"

# Copy static files
mkdir -p "../web-build/usr/local/share/serviceradar-web/.next/static"
cp -r .next/static "../web-build/usr/local/share/serviceradar-web/.next/"

# Copy public files if they exist
if [ -d "public" ]; then
  cp -r public "../web-build/usr/local/share/serviceradar-web/"
fi

cd ../web-build

# Create web configuration file
cat > etc/serviceradar/web.json << EOF
{
  "port": 3000,
  "host": "0.0.0.0",
  "api_url": "http://localhost:8090"
}
EOF

# Create Nginx configuration
cat > etc/nginx/conf.d/serviceradar-web.conf << EOF
# ServiceRadar Web Interface - Nginx Configuration
server {
    listen 80;
    server_name _; # Catch-all server name

    access_log /var/log/nginx/serviceradar-web.access.log;
    error_log /var/log/nginx/serviceradar-web.error.log;

    # API proxy (assumes serviceradar-core package is installed)
    location /api/ {
        proxy_pass http://localhost:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Support for Next.js WebSockets (if used)
    location /_next/webpack-hmr {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Main app - proxy all requests to Next.js
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Create systemd service file
cat > lib/systemd/system/serviceradar-web.service << EOF
[Unit]
Description=ServiceRadar Web Interface
After=network.target

[Service]
Type=simple
User=serviceradar
WorkingDirectory=/usr/local/share/serviceradar-web
Environment=NODE_ENV=production
Environment=PORT=3000
EnvironmentFile=/etc/serviceradar/api.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "Web package files prepared successfully"