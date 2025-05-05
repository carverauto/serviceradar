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

# Post-install script for ServiceRadar Proton Server
set -e

echo "Setting up ServiceRadar Proton Server..."

# Create proton group if it doesn't exist
if ! getent group proton >/dev/null; then
    echo "Creating proton group..."
    groupadd --system proton
fi

# Create proton user if it doesn't exist
if ! id -u proton >/dev/null 2>&1; then
    echo "Creating proton user..."
    useradd --system --no-create-home --shell /bin/false --home-dir /nonexistent -g proton proton
fi

# Set up ulimits for the proton user
echo "Setting up ulimits for proton user..."
cat > /etc/security/limits.d/proton.conf << EOF
proton	soft	nofile	1048576
proton	hard	nofile	1048576
EOF

# Create required directories
echo "Creating required directories..."
mkdir -p /var/lib/proton/{tmp,checkpoint,nativelog/meta,nativelog/log,user_files}
mkdir -p /var/log/proton-server
mkdir -p /var/run/proton-server
mkdir -p /etc/proton-server/config.d
mkdir -p /etc/proton-server/users.d

# Generate a random password
RANDOM_PASSWORD=$(openssl rand -hex 16)
PASSWORD_HASH=$(echo -n "$RANDOM_PASSWORD" | sha256sum | awk '{print $1}')

# Create the password XML file with the generated hash
echo "Configuring default user password..."
cat > /etc/proton-server/users.d/default-password.xml << EOF
<proton>
    <users>
        <default>
            <password remove='1' />
            <password_sha256_hex>${PASSWORD_HASH}</password_sha256_hex>
        </default>
    </users>
</proton>
EOF

echo "Generated password: $RANDOM_PASSWORD" > /etc/proton-server/generated_password.txt
chmod 600 /etc/proton-server/generated_password.txt

# Create symbolic links
echo "Creating symbolic links..."
ln -sf /usr/bin/proton /usr/bin/proton-server || echo "Warning: Failed to create proton-server symlink"
ln -sf /usr/bin/proton /usr/bin/proton-client || echo "Warning: Failed to create proton-client symlink"
ln -sf /usr/bin/proton /usr/bin/proton-local || echo "Warning: Failed to create proton-local symlink"

# Verify and set permissions for configuration files
echo "Verifying configuration files..."
for file in config.yaml users.yaml grok-patterns; do
    dest="/etc/proton-server/$file"
    if [ -f "$dest" ]; then
        chmod 644 "$dest" || { echo "Error: Failed to set permissions on $dest"; exit 1; }
        echo "Verified $dest"
    elif [ "$file" = "grok-patterns" ]; then
        echo "Warning: $dest not found, creating empty file"
        touch "$dest" || { echo "Error: Failed to create empty $dest"; exit 1; }
        chmod 644 "$dest" || { echo "Error: Failed to set permissions on $dest"; exit 1; }
        echo "Created empty $dest"
    else
        echo "Error: Required file $dest missing"
        exit 1
    fi
done

# Create access directory
mkdir -p /var/lib/proton/access/ || { echo "Error: Failed to create access directory"; exit 1; }

# Set correct capabilities for proton binary
echo "Setting capabilities for proton binary..."
setcap cap_net_admin,cap_ipc_lock,cap_sys_nice=ep /usr/bin/proton || { echo "Error: Failed to set capabilities"; exit 1; }

# Set ownership and permissions
echo "Setting correct ownership and permissions..."
chown -R proton:proton /etc/proton-server || { echo "Error: Failed to set ownership for /etc/proton-server"; exit 1; }
chown -R proton:proton /var/log/proton-server || { echo "Error: Failed to set ownership for /var/log/proton-server"; exit 1; }
chown -R proton:proton /var/run/proton-server || { echo "Error: Failed to set ownership for /var/run/proton-server"; exit 1; }
chown proton:proton /var/lib/proton || { echo "Error: Failed to set ownership for /var/lib/proton"; exit 1; }
chmod 755 /usr/bin/proton || { echo "Error: Failed to set permissions on /usr/bin/proton"; exit 1; }
chmod 700 /etc/proton-server/users.d || { echo "Error: Failed to set permissions on /etc/proton-server/users.d"; exit 1; }
chmod 700 /etc/proton-server/config.d || { echo "Error: Failed to set permissions on /etc/proton-server/config.d"; exit 1; }

# Enable and start the service
echo "Configuring systemd service..."
systemctl daemon-reload || { echo "Error: Failed to reload systemd daemon"; exit 1; }
systemctl enable serviceradar-proton || { echo "Error: Failed to enable serviceradar-proton service"; exit 1; }
if ! systemctl start serviceradar-proton; then
    echo "WARNING: Failed to start serviceradar-proton service. Please check the logs."
    echo "Run: journalctl -u serviceradar-proton.service"
    exit 1
fi

echo "ServiceRadar Proton Server installed successfully!"
echo "A secure password has been generated and saved to /etc/proton-server/generated_password.txt"
echo "Note: Password authentication is not used due to mTLS configuration."