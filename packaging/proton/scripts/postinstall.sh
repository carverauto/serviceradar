#!/bin/bash

set -e

# Logging functions
log_info() { echo "ServiceRadar Proton: $1"; }
log_warning() { echo "ServiceRadar Proton WARNING: $1"; }
log_error() { echo "ServiceRadar Proton ERROR: $1"; exit 1; }

# Create proton group and user
log_info "Creating proton group..."
if ! getent group proton >/dev/null; then
    groupadd -r proton || log_error "Failed to create proton group"
fi

log_info "Creating proton user..."
if ! getent passwd proton >/dev/null; then
    useradd -r -g proton -d /var/lib/proton -s /sbin/nologin -c "ServiceRadar Proton Server" proton || log_error "Failed to create proton user"
fi

# Set up ulimits
log_info "Setting up ulimits for proton user..."
echo "proton soft nofile 100000" > /etc/security/limits.d/proton.conf
echo "proton hard nofile 100000" >> /etc/security/limits.d/proton.conf

# Configure sysctl settings (skip in containers)
log_info "Configuring sysctl settings..."
if [ ! -f /proc/1/cgroup ] || ! grep -q 'lxc\|docker' /proc/1/cgroup; then
    sysctl_settings=(
        "kernel.threads-max=100000"
        "kernel.pid_max=100000"
        "vm.nr_hugepages=0"
    )
    for setting in "${sysctl_settings[@]}"; do
        if ! sysctl -w "$setting" >/dev/null 2>&1; then
            log_warning "Failed to apply sysctl setting '$setting'. If running in a container, apply this on the host:"
            log_warning "  sudo sysctl -w $setting"
        fi
    done
else
    log_warning "Running in a container, skipping sysctl settings"
fi

# Disable transparent huge pages (skip in containers)
log_info "Disabling transparent huge pages..."
if [ ! -f /proc/1/cgroup ] || ! grep -q 'lxc\|docker' /proc/1/cgroup; then
    for file in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
        if [ -w "$file" ]; then
            echo never > "$file" || log_warning "Failed to disable transparent huge pages in $file. If running in a container, run on the host:"
            log_warning "  sudo echo never > $file"
        else
            log_warning "Cannot write to $file. If running in a container, run on the host:"
            log_warning "  sudo echo never > $file"
        fi
    done
else
    log_warning "Running in a container, skipping transparent huge page settings"
fi

# Create required directories
log_info "Creating required directories..."
dirs=(
    /var/lib/proton
    /var/lib/proton/tmp
    /var/lib/proton/checkpoint
    /var/lib/proton/nativelog/meta
    /var/lib/proton/nativelog/log
    /var/lib/proton/user_files
    /var/log/proton-server
    /etc/proton-server
    /etc/serviceradar/certs
)
for dir in "${dirs[@]}"; do
    mkdir -p "$dir" || log_error "Failed to create directory $dir"
    if [[ "$dir" == /etc/serviceradar/* ]]; then
        chown serviceradar:serviceradar "$dir" || log_error "Failed to set ownership on $dir"
        chmod 750 "$dir" || log_error "Failed to set permissions on $dir"
    else
        chown proton:proton "$dir" || log_error "Failed to set ownership on $dir"
        chmod 750 "$dir" || log_error "Failed to set permissions on $dir"
    fi
done

# Verify configuration files
log_info "Verifying configuration files..."
for file in config.yaml users.yaml grok-patterns; do
    dest="/etc/proton-server/$file"
    if [ -f "$dest" ]; then
        log_info "Verified $dest"
    else
        log_error "Configuration file $dest missing"
    fi
done

# Generate mTLS certificates
log_info "Generating mTLS certificates..."
if [ ! -f /etc/serviceradar/certs/root.pem ] || [ ! -f /etc/proton-server/core.pem ] || [ ! -f /etc/serviceradar/certs/core.pem ]; then
    /usr/local/bin/serviceradar generate-tls --cert-dir /etc/serviceradar/certs --proton-dir /etc/proton-server --component proton,core --ip 127.0.0.1 --non-interactive > /tmp/serviceradar-proton-tls.log 2>&1 || {
        log_error "Failed to generate mTLS certificates. See /tmp/serviceradar-proton-tls.log for details"
    }
    log_info "mTLS certificates generated successfully"
else
    log_info "Existing certificates found, verifying..."
    if ! openssl verify -CAfile /etc/serviceradar/certs/root.pem /etc/proton-server/core.pem >/dev/null 2>&1; then
        log_error "Certificate verification failed for /etc/proton-server/core.pem"
    fi
    if ! openssl verify -CAfile /etc/serviceradar/certs/root.pem /etc/serviceradar/certs/core.pem >/dev/null 2>&1; then
        log_error "Certificate verification failed for /etc/serviceradar/certs/core.pem"
    fi
fi

# Ensure CA certificate consistency
log_info "Ensuring CA certificate consistency..."
cp /etc/serviceradar/certs/root.pem /etc/proton-server/ca-cert.pem || log_error "Failed to copy CA certificate to /etc/proton-server/ca-cert.pem"
cp /etc/serviceradar/certs/root.pem /etc/proton-server/root.pem || log_error "Failed to copy CA certificate to /etc/proton-server/root.pem"
chmod 644 /etc/proton-server/ca-cert.pem /etc/proton-server/root.pem
chown proton:proton /etc/proton-server/ca-cert.pem /etc/proton-server/root.pem

# Verify certificates
log_info "Verifying certificates..."
if ! openssl verify -CAfile /etc/proton-server/ca-cert.pem /etc/proton-server/core.pem >/dev/null 2>&1; then
    log_error "Certificate verification failed for /etc/proton-server/core.pem"
fi
if ! diff /etc/serviceradar/certs/root.pem /etc/proton-server/ca-cert.pem >/dev/null; then
    log_error "CA certificate mismatch between /etc/serviceradar/certs/root.pem and /etc/proton-server/ca-cert.pem"
fi
if ! diff /etc/serviceradar/certs/root.pem /etc/proton-server/root.pem >/dev/null; then
    log_error "CA certificate mismatch between /etc/serviceradar/certs/root.pem and /etc/proton-server/root.pem"
fi

# Generate random password
log_info "Generating random password..."
password=$(openssl rand -hex 16)
echo "$password" > /etc/proton-server/generated_password.txt
chmod 600 /etc/proton-server/generated_password.txt
chown proton:proton /etc/proton-server/generated_password.txt

# Configure default user password
log_info "Configuring default user password..."
sed -i "s|<password>|$password|" /etc/proton-server/users.yaml || log_error "Failed to update password in users.yaml"

# Update core.json with database password (if exists)
log_info "Updating /etc/serviceradar/core.json with database password..."
if [ -f /etc/serviceradar/core.json ]; then
    jq --arg pass "$password" '.Database.Password = $pass' /etc/serviceradar/core.json > /tmp/core.json.tmp && mv /tmp/core.json.tmp /etc/serviceradar/core.json || log_error "Failed to update core.json"
    log_info "Successfully updated /etc/serviceradar/core.json"
else
    log_warning "/etc/serviceradar/core.json not found, skipping password update"
fi

# Create symbolic links
log_info "Creating symbolic links..."
systemctl enable serviceradar-proton.service || log_error "Failed to enable serviceradar-proton service"

# Set capabilities for proton binary
log_info "Setting capabilities for proton binary..."
setcap CAP_NET_BIND_SERVICE=+ep /usr/bin/proton || log_error "Failed to set capabilities for /usr/bin/proton"

# Set ownership and permissions
log_info "Setting ownership and permissions..."
chown -R proton:proton /var/lib/proton /var/log/proton-server /etc/proton-server || log_error "Failed to set ownership"
chmod -R 750 /var/lib/proton /var/log/proton-server /etc/proton-server || log_error "Failed to set permissions"
chmod 644 /etc/proton-server/*.pem 2>/dev/null || true
chmod 600 /etc/proton-server/*-key.pem 2>/dev/null || true

# Fix permissions on /etc/serviceradar/certs/
log_info "Fixing permissions on /etc/serviceradar/certs/"
if [ -d /etc/serviceradar/certs ]; then
    chown -R serviceradar:serviceradar /etc/serviceradar/certs || log_warning "Failed to set ownership on /etc/serviceradar/certs"
    chmod 750 /etc/serviceradar/certs || log_warning "Failed to set permissions on /etc/serviceradar/certs"
    chmod 644 /etc/serviceradar/certs/*.pem 2>/dev/null || true
    chmod 600 /etc/serviceradar/certs/*-key.pem 2>/dev/null || true
fi

# Configure systemd service
log_info "Configuring systemd service..."
systemctl daemon-reload || log_error "Failed to reload systemd daemon"
systemctl start serviceradar-proton || log_error "Failed to start serviceradar-proton service"

# Fix permissions of log files
log_info "Fixing permissions of log files..."
find /var/log/proton-server -type f -exec chown proton:proton {} \; -exec chmod 640 {} \; || log_warning "Failed to fix log file permissions"

# Restart services
log_info "Restarting proton service..."
systemctl restart serviceradar-proton || log_error "Failed to restart serviceradar-proton service"

log_info "ServiceRadar Proton Server installed successfully!"
log_info "A secure password has been generated and saved to /etc/proton-server/generated_password.txt"
log_info "Note: Password authentication is not used due to mTLS configuration."