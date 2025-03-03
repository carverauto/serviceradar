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

# setup.sh - Create packaging structure for ServiceRadar components
set -e

echo "Creating packaging structure..."

# Create packaging structure
mkdir -p packaging/{agent,poller,cloud,dusk}/{config,systemd,scripts}

# Function to get component directory name
get_component_dir() {
    case $1 in
        "dusk-checker") echo "dusk" ;;
        *) echo "$1" ;;
    esac
}

# Extract configuration files from setup scripts
for script in setup-deb-*.sh; do
    component=$(echo $script | sed 's/setup-deb-\(.*\)\.sh/\1/')
    component_dir=$(get_component_dir "$component")
    echo "Processing $component (directory: $component_dir)..."

    # Copy setup script as reference
    cp "$script" "packaging/$component_dir/scripts/package.sh"

    # Extract config and systemd files based on component
    case $component in
        "agent")
            # Extract agent configuration
            awk '/cat > "\${PKG_ROOT}\/etc\/serviceradar\/agent.json"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/agent/config/agent.json"

            # Extract systemd service
            awk '/cat > "\${PKG_ROOT}\/lib\/systemd\/system\/serviceradar-agent.service"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/agent/systemd/serviceradar-agent.service"
            ;;

        "poller")
            # Extract poller configuration
            awk '/cat > "\${PKG_ROOT}\/etc\/serviceradar\/poller.json"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/poller/config/poller.json"

            # Extract systemd service
            awk '/cat > "\${PKG_ROOT}\/lib\/systemd\/system\/serviceradar-poller.service"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/poller/systemd/serviceradar-poller.service"
            ;;

        "cloud")
            # Extract cloud configuration
            awk '/cat > "\${PKG_ROOT}\/etc\/serviceradar\/cloud.json"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/cloud/config/cloud.json"

            # Extract systemd service
            awk '/cat > "\${PKG_ROOT}\/lib\/systemd\/system\/serviceradar-cloud.service"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/cloud/systemd/serviceradar-cloud.service"
            ;;

        "dusk-checker")
            # Extract dusk configuration
            awk '/cat > "\${PKG_ROOT}\/etc\/serviceradar\/checkers\/dusk.json"/,/^EOF/' "$script" | sed '1d;$d' > "packaging/dusk/config/dusk.json"
            ;;
    esac
done

# Create postinstall and preremove scripts for each component
for component_dir in agent poller cloud dusk; do
    echo "Creating install scripts for $component_dir..."

    # Create postinstall script
    cat > "packaging/${component_dir}/scripts/postinstall.sh" << 'EOF'
#!/bin/sh
set -e

# Create serviceradar user if it doesn't exist
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi

# Create required directories
mkdir -p /etc/serviceradar
mkdir -p /var/lib/serviceradar

# Create checkers directory if this is the dusk component
if [ "${component_dir}" = "dusk" ]; then
    mkdir -p /etc/serviceradar/checkers
fi

# Set permissions
chown -R serviceradar:serviceradar /etc/serviceradar
chmod -R 755 /etc/serviceradar

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable "serviceradar-${component_dir}"
    systemctl start "serviceradar-${component_dir}"
fi

# Set required capability for ICMP scanning if this is the agent
if [ "${component_dir}" = "agent" ] && [ -x /usr/local/bin/serviceradar-agent ]; then
    setcap cap_net_raw=+ep /usr/local/bin/serviceradar-agent
fi
EOF

    # Create preremove script
    cat > "packaging/${component_dir}/scripts/preremove.sh" << 'EOF'
#!/bin/sh
set -e

# Only try to manage service if it exists
if [ -f "/lib/systemd/system/serviceradar-${component_dir}.service" ]; then
    # Stop and disable service
    systemctl stop "serviceradar-${component_dir}"
    systemctl disable "serviceradar-${component_dir}"
fi
EOF

    # Make scripts executable
    chmod +x "packaging/${component_dir}/scripts/"{postinstall,preremove}.sh
done

echo "Packaging structure created successfully!"
echo "Directory structure:"
find packaging -type f | sort