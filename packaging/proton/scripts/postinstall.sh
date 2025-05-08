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

# Logging functions
log_info() {
    echo "ServiceRadar Proton: $1"
}

log_warning() {
    echo "ServiceRadar Proton WARNING: $1"
}

log_error() {
    echo "ServiceRadar Proton ERROR: $1" >&2
    exit 1
}

# Check for required tools
if ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl is required but not installed"
fi

if ! command -v setcap >/dev/null 2>&1; then
    log_error "setcap is required but not installed (libcap2-bin missing). Please install libcap2-bin."
fi

if ! command -v /usr/local/bin/serviceradar >/dev/null 2>&1; then
    log_error "serviceradar-cli is required but not installed. Please install serviceradar-cli."
fi

log_info "Setting up ServiceRadar Proton Server..."

# Generate mTLS certificates if /etc/serviceradar/certs does not exist
if [ ! -d "/etc/serviceradar/certs" ]; then
    log_info "Certificate directory /etc/serviceradar/certs not found. Generating mTLS certificates..."
    /usr/local/bin/serviceradar generate-tls --non-interactive --cert-dir /etc/serviceradar/certs --proton-dir /etc/proton-server || {
        log_error "Failed to generate mTLS certificates using serviceradar-cli"
    }
    log_info "mTLS certificates generated successfully"
fi

# Create proton group if it doesn't exist
if ! getent group proton >/dev/null; then
    log_info "Creating proton group..."
    groupadd --system proton || log_error "Failed to create proton group"
fi

# Create proton user if it doesn't exist
if ! id -u proton >/dev/null 2>&1; then
    log_info "Creating proton user..."
    useradd --system --no-create-home --shell /bin/false --home-dir /nonexistent -g proton proton || log_error "Failed to create proton user"
fi

# Set up ulimits for the proton user
log_info "Setting up ulimits for proton user..."
mkdir -p /etc/security/limits.d || log_error "Failed to create /etc/security/limits.d"
cat > /etc/security/limits.d/proton.conf << EOF
proton soft nofile 1048576
proton hard nofile 1048576
proton soft nproc 65535
proton hard nproc 65535
EOF
chmod 644 /etc/security/limits.d/proton.conf || log_error "Failed to set permissions on proton.conf"

# Configure sysctl settings (optional for LXC)
log_info "Configuring sysctl settings..."
mkdir -p /etc/sysctl.d || log_error "Failed to create /etc/sysctl.d"
cat > /etc/sysctl.d/99-clickhouse.conf << EOF
kernel.threads-max=100000
kernel.pid_max=100000
vm.nr_hugepages=0
EOF
chmod 644 /etc/sysctl.d/99-clickhouse.conf || log_error "Failed to set permissions on 99-clickhouse.conf"

# Apply sysctl settings individually to handle LXC restrictions
for setting in "kernel.threads-max=100000" "kernel.pid_max=100000" "vm.nr_hugepages=0"; do
    sysctl -w "$setting" >/dev/null 2>&1 || {
        log_warning "Failed to apply sysctl setting '$setting'. If running in an LXC container, apply this on the host:"
        log_warning "  sudo sysctl -w $setting"
    }
done

# Disable transparent huge pages (optional for LXC)
log_info "Disabling transparent huge pages..."
for file in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    if [ -f "$file" ]; then
        echo never > "$file" 2>/dev/null || {
            log_warning "Failed to disable transparent huge pages in $file. If running in an LXC container, run on the host:"
            log_warning "  sudo echo never > $file"
        }
    else
        log_warning "Transparent huge page file $file not found. This may be normal in some environments."
    fi
done

# Create required directories
log_info "Creating required directories..."
for dir in /var/lib/proton/tmp /var/lib/proton/checkpoint /var/lib/proton/nativelog/meta /var/lib/proton/nativelog/log /var/lib/proton/user_files /var/log/proton-server /var/run/proton-server /etc/proton-server/config.d /etc/proton-server/users.d /var/lib/proton/access; do
    mkdir -p "$dir" || log_error "Failed to create directory $dir"
done

# Copy configuration files from /usr/share/serviceradar-proton/ to /etc/proton-server/ if not already present
# Copy configuration files to /etc/proton-server/
log_info "Copying configuration files..."
mkdir -p /etc/proton-server || log_error "Failed to create /etc/proton-server directory"
for file in config.yaml users.yaml grok-patterns; do
    src="/usr/share/serviceradar-proton/$file"
    dest="/etc/proton-server/$file"
    if [ -f "$dest" ]; then
        log_info "$dest already exists, skipping copy"
    elif [ -f "$src" ]; then
        cp "$src" "$dest" || log_error "Failed to copy $src to $dest"
        chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
        chown proton:proton "$dest" || log_error "Failed to set ownership on $dest"
        log_info "Copied $src to $dest"
    else
        if [ "$file" = "grok-patterns" ]; then
            log_info "Creating empty $dest"
            touch "$dest" || log_error "Failed to create empty $dest"
            chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
            chown proton:proton "$dest" || log_error "Failed to set ownership on $dest"
        else
            log_error "Configuration file $src not found and $dest missing"
        fi
    fi
done

# Verify configuration files
log_info "Verifying configuration files..."
for file in config.yaml users.yaml grok-patterns; do
    dest="/etc/proton-server/$file"
    if [ -f "$dest" ]; then
        chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
        chown proton:proton "$dest" || log_error "Failed to set ownership on $dest"
        log_info "Verified $dest"
    elif [ "$file" = "grok-patterns" ]; then
        log_info "Creating empty $dest"
        touch "$dest" || log_error "Failed to create empty $dest"
        chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
        chown proton:proton "$dest" || log_error "Failed to set ownership on $dest"
    else
        log_error "Required file $dest missing"
    fi
done

# Generate a random password
log_info "Generating random password..."
RANDOM_PASSWORD=$(openssl rand -hex 16) || log_error "Failed to generate random password"
PASSWORD_HASH=$(echo -n "$RANDOM_PASSWORD" | sha256sum | awk '{print $1}') || log_error "Failed to generate password hash"

# Create the password XML file with the generated hash
log_info "Configuring default user password..."
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
chmod 600 /etc/proton-server/users.d/default-password.xml || log_error "Failed to set permissions on default-password.xml"

echo "Generated password: $RANDOM_PASSWORD" > /etc/proton-server/generated_password.txt
chmod 600 /etc/proton-server/generated_password.txt || log_error "Failed to set permissions on generated_password.txt"

# Update core.json with the generated password
log_info "Updating /etc/serviceradar/core.json with database password..."
if [ -f "/etc/serviceradar/core.json" ]; then
    /usr/local/bin/serviceradar update-config --file /etc/serviceradar/core.json --db-password-file /etc/proton-server/generated_password.txt || {
        log_error "Failed to update /etc/serviceradar/core.json with database password"
    }
    log_info "Successfully updated /etc/serviceradar/core.json"
    chown serviceradar:serviceradar /etc/serviceradar/core.json 2>/dev/null || log_warning "Failed to set ownership of /etc/serviceradar/core.json"
else
    log_warning "/etc/serviceradar/core.json not found, skipping database password update"
fi

# Create symbolic links
log_info "Creating symbolic links..."
for link in proton-server proton-client proton-local; do
    ln -sf /usr/bin/proton /usr/bin/$link 2>/dev/null || log_warning "Failed to create symlink /usr/bin/$link"
done

# Verify and set permissions for configuration files
log_info "Verifying configuration files..."
for file in config.yaml users.yaml grok-patterns; do
    dest="/etc/proton-server/$file"
    if [ -f "$dest" ]; then
        chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
        log_info "Verified $dest"
    elif [ "$file" = "grok-patterns" ]; then
        log_info "Creating empty $dest"
        touch "$dest" || log_error "Failed to create empty $dest"
        chmod 644 "$dest" || log_error "Failed to set permissions on $dest"
    else
        log_error "Required file $dest missing"
    fi
done

# Set correct capabilities for proton binary
log_info "Setting capabilities for proton binary..."
setcap cap_net_admin,cap_ipc_lock,cap_sys_nice=ep /usr/bin/proton || {
    log_error "Failed to set capabilities on /usr/bin/proton. The proton service requires cap_net_admin,cap_ipc_lock,cap_sys_nice to function."
}

# Set ownership and permissions
log_info "Setting ownership and permissions..."
chown -R proton:proton /usr/bin/proton /etc/proton-server /var/log/proton-server /var/run/proton-server /var/lib/proton || log_error "Failed to set ownership"
chmod 755 /usr/bin/proton || log_error "Failed to set permissions on /usr/bin/proton"
chmod 700 /etc/proton-server/users.d /etc/proton-server/config.d || log_error "Failed to set permissions on config directories"

# Enable and start the service
log_info "Configuring systemd service..."
systemctl daemon-reload 2>/dev/null || log_error "Failed to reload systemd daemon"
systemctl enable serviceradar-proton 2>/dev/null || log_error "Failed to enable serviceradar-proton service"
if ! systemctl start serviceradar-proton 2>/dev/null; then
    log_warning "Failed to start serviceradar-proton service. Please check the logs:"
    log_warning "  journalctl -u serviceradar-proton.service"
else
    log_info "ServiceRadar Proton service started successfully"
fi

# fix the permissions of the logfiles one more time and then restart proton
log_info "Fixing permissions of log files..."
chown -R proton:proton /var/log/proton-server || log_error "Failed to set ownership on /var/log/proton-server"
log_info "Fixing permissions on /etc/serviceradar/certs/"
chown serviceradar:serviceradar certs/
# restart proton
log_info "Restarting proton service..."
systemctl restart serviceradar-proton 2>/dev/null || log_error "Failed to restart serviceradar-proton service"
log_info "Restarting serviceradar-core service..."
systemctl restart serviceradar-core 2>/dev/null || log_error "Failed to restart serviceradar-core service"

log_info "ServiceRadar Proton Server installed successfully!"
log_info "A secure password has been generated and saved to /etc/proton-server/generated_password.txt"
log_info "Note: Password authentication is not used due to mTLS configuration."