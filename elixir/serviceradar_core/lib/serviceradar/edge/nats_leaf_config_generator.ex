defmodule ServiceRadar.Edge.NatsLeafConfigGenerator do
  @moduledoc """
  Generates NATS leaf server configuration files.

  Configuration is based on the template at `packaging/nats/config/nats-leaf.conf`
  and includes:

  - Server name based on edge site slug
  - Local listener for collector connections (mTLS)
  - JetStream with "edge" domain for local buffering
  - Leaf node connection to SaaS NATS cluster (mTLS)

  ## Certificate Paths

  The generated config uses standard paths:
  - `/etc/nats/certs/nats-server.pem` - Server certificate for local clients
  - `/etc/nats/certs/nats-server-key.pem` - Server private key
  - `/etc/nats/certs/nats-leaf.pem` - Leaf certificate for upstream
  - `/etc/nats/certs/nats-leaf-key.pem` - Leaf private key
  - `/etc/nats/certs/ca-chain.pem` - CA certificate chain
  - `/etc/nats/creds/tenant.creds` - NATS account credentials
  """

  @doc """
  Generates the NATS leaf configuration for an edge site.

  ## Parameters

  - `edge_site` - The EdgeSite record
  - `leaf_server` - The NatsLeafServer record
  - `opts` - Additional options

  ## Options

  - `:local_listen` - Override local listen address (default from leaf_server)
  - `:jetstream_max_memory` - JetStream memory limit (default: "1G")
  - `:jetstream_max_file` - JetStream file limit (default: "10G")
  - `:debug` - Enable debug logging (default: false)

  ## Returns

  The NATS configuration file content as a string.
  """
  @spec generate_config(map(), map(), keyword()) :: String.t()
  def generate_config(edge_site, leaf_server, opts \\ []) do
    local_listen = Keyword.get(opts, :local_listen, leaf_server.local_listen || "0.0.0.0:4222")
    jetstream_max_memory = Keyword.get(opts, :jetstream_max_memory, "1G")
    jetstream_max_file = Keyword.get(opts, :jetstream_max_file, "10G")
    debug = Keyword.get(opts, :debug, false)

    server_name = "nats-#{edge_site.slug}"

    """
    # NATS Leaf Server Configuration
    # Generated for EdgeSite: #{edge_site.name} (#{edge_site.slug})
    # Generated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    server_name: #{server_name}
    logfile: "/var/log/nats/nats.log"
    debug: #{debug}

    # Listen for local clients (collectors)
    listen: #{local_listen}

    # Enable mTLS for local client communication
    tls {
        cert_file: "/etc/nats/certs/nats-server.pem"
        key_file: "/etc/nats/certs/nats-server-key.pem"
        ca_file: "/etc/nats/certs/ca-chain.pem"
        verify_and_map: true
    }

    # Enable JetStream for local buffering during WAN outages
    jetstream {
        store_dir: /var/lib/nats/jetstream
        max_memory_store: #{jetstream_max_memory}
        max_file_store: #{jetstream_max_file}
        domain: edge
    }

    # Leaf Node configuration to connect to the SaaS NATS cluster
    leafnodes {
        remotes = [
            {
                url: "#{leaf_server.upstream_url}"

                # Use tenant NATS account credentials
                credentials: "/etc/nats/creds/tenant.creds"

                # mTLS configuration for leaf-to-SaaS connection
                tls {
                    cert_file: "/etc/nats/certs/nats-leaf.pem"
                    key_file: "/etc/nats/certs/nats-leaf-key.pem"
                    ca_file: "/etc/nats/certs/ca-chain.pem"
                }
            }
        ]
    }
    """
  end

  @doc """
  Generates the setup script for deploying the NATS leaf server.

  The script:
  1. Creates required directories
  2. Copies certificates and configuration
  3. Sets up systemd service
  4. Enables and starts the service
  """
  @spec generate_setup_script(map()) :: String.t()
  def generate_setup_script(edge_site) do
    """
    #!/bin/bash
    # NATS Leaf Server Setup Script
    # Generated for EdgeSite: #{edge_site.name} (#{edge_site.slug})

    set -e

    echo "Setting up NATS leaf server for #{edge_site.name}..."

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root or with sudo"
        exit 1
    fi

    # Create directories
    mkdir -p /etc/nats/certs
    mkdir -p /etc/nats/creds
    mkdir -p /var/lib/nats/jetstream
    mkdir -p /var/log/nats

    # Copy certificates
    echo "Installing certificates..."
    cp nats/certs/nats-server.pem /etc/nats/certs/
    cp nats/certs/nats-server-key.pem /etc/nats/certs/
    cp nats/certs/nats-leaf.pem /etc/nats/certs/
    cp nats/certs/nats-leaf-key.pem /etc/nats/certs/
    cp nats/certs/ca-chain.pem /etc/nats/certs/

    # Copy credentials
    echo "Installing credentials..."
    cp creds/tenant.creds /etc/nats/creds/

    # Set permissions
    chmod 600 /etc/nats/certs/*.pem
    chmod 600 /etc/nats/creds/*.creds
    chown -R nats:nats /etc/nats 2>/dev/null || true
    chown -R nats:nats /var/lib/nats 2>/dev/null || true
    chown -R nats:nats /var/log/nats 2>/dev/null || true

    # Copy configuration
    echo "Installing configuration..."
    cp nats/nats-leaf.conf /etc/nats/nats-server.conf

    # Check if serviceradar-nats is installed
    if ! command -v nats-server &> /dev/null; then
        echo ""
        echo "WARNING: nats-server not found!"
        echo "Please install the serviceradar-nats package first:"
        echo "  # Debian/Ubuntu"
        echo "  apt install serviceradar-nats"
        echo ""
        echo "  # RHEL/CentOS"
        echo "  dnf install serviceradar-nats"
        echo ""
        exit 1
    fi

    # Enable and restart service
    echo "Enabling and starting NATS service..."
    systemctl daemon-reload
    systemctl enable nats-server
    systemctl restart nats-server

    # Check status
    sleep 2
    if systemctl is-active --quiet nats-server; then
        echo ""
        echo "NATS leaf server is running!"
        echo "Check status: systemctl status nats-server"
        echo "View logs: journalctl -u nats-server -f"
    else
        echo ""
        echo "ERROR: NATS server failed to start"
        echo "Check logs: journalctl -u nats-server -n 50"
        exit 1
    fi
    """
  end

  @doc """
  Generates the README for the edge site bundle.
  """
  @spec generate_readme(map(), map()) :: String.t()
  def generate_readme(edge_site, tenant) do
    """
    # NATS Leaf Server Bundle

    **Site:** #{edge_site.name}
    **Tenant:** #{tenant.name}
    **Generated:** #{DateTime.utc_now() |> DateTime.to_iso8601()}

    ## Contents

    - `nats/nats-leaf.conf` - NATS server configuration
    - `nats/certs/` - TLS certificates
      - `nats-server.pem` - Server certificate for local clients
      - `nats-server-key.pem` - Server private key
      - `nats-leaf.pem` - Leaf certificate for upstream connection
      - `nats-leaf-key.pem` - Leaf private key
      - `ca-chain.pem` - CA certificate chain
    - `creds/tenant.creds` - NATS account credentials
    - `setup.sh` - Automated setup script
    - `README.md` - This file

    ## Quick Start

    1. Install the serviceradar-nats package:

       ```bash
       # Debian/Ubuntu
       sudo apt install serviceradar-nats

       # RHEL/CentOS
       sudo dnf install serviceradar-nats
       ```

    2. Run the setup script:

       ```bash
       sudo ./setup.sh
       ```

    3. Verify the connection:

       ```bash
       systemctl status nats-server
       journalctl -u nats-server -f
       ```

    ## Manual Installation

    If you prefer to install manually:

    1. Copy certificates to `/etc/nats/certs/`
    2. Copy credentials to `/etc/nats/creds/`
    3. Copy `nats-leaf.conf` to `/etc/nats/nats-server.conf`
    4. Restart the service: `systemctl restart nats-server`

    ## Connecting Collectors

    Collectors deployed at this site should connect to:

    ```
    #{edge_site.nats_leaf_url || "nats://localhost:4222"}
    ```

    ## Troubleshooting

    ### Check service status
    ```bash
    systemctl status nats-server
    ```

    ### View logs
    ```bash
    journalctl -u nats-server -f
    ```

    ### Test local connection
    ```bash
    nats-server --config /etc/nats/nats-server.conf --test
    ```

    ### Verify upstream connection
    Check the logs for "Leafnode connection" messages indicating
    successful connection to the SaaS cluster.

    ## Certificate Expiration

    Certificates in this bundle are valid for 1 year. To renew:
    1. Download a new bundle from the ServiceRadar admin console
    2. Run the setup script again

    ## Support

    For help, contact your ServiceRadar administrator.
    """
  end
end
