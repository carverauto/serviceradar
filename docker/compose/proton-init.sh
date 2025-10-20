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

set -e

# Logging functions
log_info() {
    echo "[Proton Init] $1"
}

log_error() {
    echo "[Proton Init] ERROR: $1" >&2
    exit 1
}

# Wait for Proton to be ready
wait_for_proton() {
    log_info "Waiting for Proton to be ready..."
    for i in {1..30}; do
        if proton-client --host localhost --port 8463 --query "SELECT 1" >/dev/null 2>&1; then
            log_info "Proton is ready!"
            return 0
        fi
        log_info "Waiting for Proton... ($i/30)"
        sleep 2
    done
    log_error "Proton failed to start within 60 seconds"
}

# Generate or recover password
if [ -z "$PROTON_PASSWORD" ]; then
    # First preference: existing shared credential file
    if [ -f /etc/serviceradar/credentials/proton-password ] && \
       [ -s /etc/serviceradar/credentials/proton-password ]; then
        PROTON_PASSWORD=$(cat /etc/serviceradar/credentials/proton-password)
        log_info "Reusing Proton password from shared credentials volume"
    # Second preference: previously generated password inside Proton data dir
    elif [ -f /etc/proton-server/generated_password.txt ] && \
         [ -s /etc/proton-server/generated_password.txt ]; then
        PROTON_PASSWORD=$(cat /etc/proton-server/generated_password.txt)
        log_info "Reusing Proton password from generated_password.txt"
    else
        log_info "Generating random password..."
        PROTON_PASSWORD=$(openssl rand -hex 16)
        log_info "Generated new Proton password"
    fi
fi

# Persist password to both expected locations to keep services aligned
echo "$PROTON_PASSWORD" > /etc/proton-server/generated_password.txt
chmod 600 /etc/proton-server/generated_password.txt

if [ -d "/etc/serviceradar/credentials" ]; then
    echo "$PROTON_PASSWORD" > /etc/serviceradar/credentials/proton-password
    chmod 644 /etc/serviceradar/credentials/proton-password
    log_info "Password synchronized to shared credentials volume"
fi

# Create password hash
PASSWORD_HASH=$(echo -n "$PROTON_PASSWORD" | sha256sum | awk '{print $1}')

# Create user configuration
log_info "Configuring default user password..."
mkdir -p /etc/proton-server/users.d
cat > /etc/proton-server/users.d/default-password.xml << EOF
<proton>
    <users>
        <default>
            <password remove='1' />
            <password_sha256_hex>${PASSWORD_HASH}</password_sha256_hex>
            <networks>
                <ip>::/0</ip>
            </networks>
        </default>
    </users>
</proton>
EOF
chmod 600 /etc/proton-server/users.d/default-password.xml

# Set up ulimits
log_info "Setting up ulimits..."
ulimit -n 1048576
ulimit -u 65535

# Create required directories
log_info "Creating required directories..."
for dir in /var/lib/proton/tmp /var/lib/proton/checkpoint /var/lib/proton/nativelog/meta \
           /var/lib/proton/nativelog/log /var/lib/proton/user_files /var/log/proton-server \
           /var/run/proton-server /var/lib/proton/access; do
    mkdir -p "$dir"
    chown proton:proton "$dir"
done

# Generate DH parameters if not present (for SSL security)
log_info "Checking DH parameters..."
DH_PARAMS_PERSIST="/var/lib/proton/dhparam.pem"
DH_PARAMS_TARGET="/etc/proton-server/dhparam.pem"
mkdir -p "$(dirname "$DH_PARAMS_PERSIST")"

if [ -f "$DH_PARAMS_TARGET" ]; then
    log_info "DH parameters already present at ${DH_PARAMS_TARGET}"
elif [ -f "$DH_PARAMS_PERSIST" ]; then
    log_info "Restoring DH parameters from persistent storage"
    cp "$DH_PARAMS_PERSIST" "$DH_PARAMS_TARGET"
    chmod 644 "$DH_PARAMS_TARGET"
else
    log_info "Generating DH parameters (this may take a few minutes for security)..."
    openssl dhparam -out "$DH_PARAMS_TARGET" 2048
    chmod 644 "$DH_PARAMS_TARGET"
    cp "$DH_PARAMS_TARGET" "$DH_PARAMS_PERSIST"
    chmod 644 "$DH_PARAMS_PERSIST"
    log_info "DH parameters generated and saved to persistent storage"
fi

# Verify certificate access
log_info "Verifying certificate access..."
if [ -d "/etc/proton-server/certs" ]; then
    log_info "Certificate directory accessible at /etc/proton-server/certs"
fi

# Start Proton in background
log_info "Starting Proton server..."
exec proton server --config-file=/etc/proton-server/config.yaml
