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

# Post-install script for ServiceRadar Web package
set -e

# Check for Nginx
if ! command -v nginx >/dev/null 2>&1; then
    echo "WARNING: Nginx is not installed. It is recommended to install nginx for optimal functionality."
fi

# Check for Node.js
if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: Node.js is required but not installed. Installing Node.js..."
    if command -v dnf >/dev/null 2>&1; then
        # RHEL/CentOS/Fedora
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        dnf install -y nodejs
    elif command -v yum >/dev/null 2>&1; then
        # Older RHEL/CentOS
        curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
        yum install -y nodejs
    else
        echo "ERROR: Unable to install Node.js automatically. Please install Node.js manually."
        exit 1
    fi
fi

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Set up required directories
mkdir -p /var/lib/serviceradar
mkdir -p /etc/serviceradar

# Set proper ownership and permissions
chown -R serviceradar:serviceradar /usr/local/share/serviceradar-web
chown -R serviceradar:serviceradar /etc/serviceradar/web.json
chown -R serviceradar:serviceradar /var/lib/serviceradar
chmod 755 /usr/local/share/serviceradar-web
chmod 644 /etc/serviceradar/web.json

# Check for API key file
if [ ! -f "/etc/serviceradar/api.env" ]; then
    echo "WARNING: API key file not found. Creating a temporary API key..."
    API_KEY=$(openssl rand -hex 32)
    echo "API_KEY=$API_KEY" > /etc/serviceradar/api.env
    chmod 600 /etc/serviceradar/api.env
    chown serviceradar:serviceradar /etc/serviceradar/api.env
    echo "For proper functionality, please install the serviceradar-core package."
fi

# Configure Nginx if present
if command -v nginx >/dev/null 2>&1; then
    # Handle CentOS/RHEL style nginx config with sites-enabled
    if [ -d /etc/nginx/sites-enabled ]; then
        if [ -f /etc/nginx/sites-enabled/default ]; then
            echo "Disabling default Nginx site..."
            rm -f /etc/nginx/sites-enabled/default
        fi
        ln -sf /etc/nginx/conf.d/serviceradar-web.conf /etc/nginx/sites-enabled/
    fi

    # Test the configuration
    if nginx -t; then
        # Reload Nginx if running
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx || systemctl restart nginx
            echo "Nginx configuration updated successfully."
        else
            echo "Nginx is not running. Please start it with: systemctl start nginx"
        fi
    else
        echo "WARNING: Nginx configuration test failed. Please check your Nginx configuration."
    fi
fi

# Enable and start the web service
systemctl daemon-reload
systemctl enable serviceradar-web
if ! systemctl start serviceradar-web; then
    echo "WARNING: Failed to start serviceradar-web service. Please check the logs."
    echo "Run: journalctl -u serviceradar-web.service"
fi

# Configure SELinux if it's enabled
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Configuring SELinux policies..."
    # Allow Node.js to listen on network ports
    if command -v setsebool >/dev/null 2>&1; then
        setsebool -P httpd_can_network_connect 1
    fi
    # Set correct context for web files
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -Rv /usr/local/share/serviceradar-web
    fi
fi

# Configure firewall if firewalld is running
if systemctl is-active --quiet firewalld; then
    echo "Configuring firewall..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --reload
fi

echo "ServiceRadar Web Interface installed successfully!"
echo "Web UI is running on port 3000"
echo "Access the UI through Nginx at http://your-server-ip/"