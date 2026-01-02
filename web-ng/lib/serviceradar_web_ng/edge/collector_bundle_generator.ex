defmodule ServiceRadarWebNG.Edge.CollectorBundleGenerator do
  @moduledoc """
  Generates downloadable installation bundles for collector edge components.

  A collector bundle contains everything needed to configure an already-installed collector:
  - NATS credentials file (.creds) for tenant-isolated messaging
  - mTLS certificates for secure communication
  - Collector configuration file (TOML for flowgger/otel, JSON for trapd/netflow)
  - Update script to copy files and restart the service

  ## Bundle Structure

      collector-package-<id>/
      ├── creds/
      │   └── nats.creds           # NATS account credentials
      ├── certs/
      │   ├── collector.pem        # TLS certificate
      │   ├── collector-key.pem    # TLS private key
      │   └── ca-chain.pem         # CA certificate chain
      ├── config/
      │   └── <collector>.toml     # Collector configuration (or .json)
      ├── update.sh                # Script to copy files and restart service
      └── README.md                # Installation instructions

  ## Prerequisites

  Collectors must be installed via platform packages (deb/rpm) before using this bundle.
  The bundle only updates credentials, certificates, and configuration.
  """

  alias ServiceRadar.Edge.CollectorPackage

  @doc """
  Creates a tarball bundle for the given collector package.

  ## Parameters

    * `package` - The CollectorPackage struct (must have TLS certs populated)
    * `nats_creds` - The decrypted NATS credentials content
    * `tls_key_pem` - The decrypted TLS private key
    * `opts` - Additional options:
      * `:nats_url` - NATS server URL (default: from config)
      * `:core_address` - Core service address (default: from config)

  ## Returns

    * `{:ok, tarball_binary}` - The gzipped tarball as binary
    * `{:error, reason}` - If bundle creation fails
  """
  @spec create_tarball(CollectorPackage.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def create_tarball(package, nats_creds, tls_key_pem, opts \\ []) do
    package_dir = "collector-package-#{short_id(package.id)}"

    # Build the file list for the tarball
    files = [
      # Credentials
      {"#{package_dir}/creds/nats.creds", nats_creds},
      # TLS certificates
      {"#{package_dir}/certs/collector.pem", package.tls_cert_pem},
      {"#{package_dir}/certs/collector-key.pem", tls_key_pem},
      {"#{package_dir}/certs/ca-chain.pem", package.ca_chain_pem},
      # Configuration
      {"#{package_dir}/config/#{config_filename(package)}", generate_config(package, opts)},
      # Scripts and docs
      {"#{package_dir}/update.sh", generate_update_script(package)},
      {"#{package_dir}/README.md", generate_readme(package)}
    ]

    # Create the tarball
    create_tar_gz(files)
  end

  @doc """
  Returns the bundle filename for a collector package.
  """
  @spec bundle_filename(CollectorPackage.t()) :: String.t()
  def bundle_filename(package) do
    "collector-package-#{short_id(package.id)}.tar.gz"
  end

  @doc """
  Generates a one-liner install command for updating an existing collector.
  """
  @spec update_command(CollectorPackage.t(), String.t(), keyword()) :: String.t()
  def update_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())

    """
    curl -fsSL "#{base_url}/api/edge/collectors/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd collector-package-#{short_id(package.id)} && \\
    sudo ./update.sh
    """
    |> String.trim()
  end

  # Private functions

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp config_filename(package) do
    case package.collector_type do
      :flowgger -> "flowgger.toml"
      :otel -> "otel.toml"
      :trapd -> "trapd.json"
      :netflow -> "netflow.json"
      _ -> "config.toml"
    end
  end

  defp generate_config(package, opts) do
    case package.collector_type do
      :flowgger -> generate_flowgger_config(package, opts)
      :otel -> generate_otel_config(package, opts)
      :trapd -> generate_trapd_config(package, opts)
      :netflow -> generate_netflow_config(package, opts)
      _ -> generate_flowgger_config(package, opts)
    end
  end

  defp generate_flowgger_config(package, opts) do
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())
    core_address = Keyword.get(opts, :core_address, default_core_address())
    site = package.site || "default"

    # Apply any config overrides
    input_listen = get_in(package.config_overrides, ["input", "listen"]) || "0.0.0.0:514"
    input_format = get_in(package.config_overrides, ["input", "format"]) || "rfc3164"

    """
    # ServiceRadar Flowgger Configuration
    # Package ID: #{package.id}
    # Site: #{site}
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    [input]
    type = "udp"
    listen = "#{input_listen}"
    format = "#{input_format}"

    [output]
    type = "nats"
    format = "gelf"
    framing = "noop"
    partition = "#{site}"
    nats_url = "#{nats_url}"
    nats_subject = "events.syslog"
    nats_stream = "events"
    nats_tls_ca_file = "/etc/serviceradar/certs/ca-chain.pem"
    nats_tls_cert = "/etc/serviceradar/certs/collector.pem"
    nats_tls_key = "/etc/serviceradar/certs/collector-key.pem"
    nats_creds_file = "/etc/serviceradar/creds/nats.creds"

    [grpc]
    listen_addr = "127.0.0.1:50044"
    mode = "mtls"
    cert_dir = "/etc/serviceradar/certs"
    cert_file = "/etc/serviceradar/certs/collector.pem"
    key_file = "/etc/serviceradar/certs/collector-key.pem"
    ca_file = "/etc/serviceradar/certs/ca-chain.pem"
    core_address = "#{core_address}"
    """
  end

  defp generate_otel_config(package, opts) do
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())
    core_address = Keyword.get(opts, :core_address, default_core_address())
    site = package.site || "default"

    # Apply any config overrides
    grpc_port = get_in(package.config_overrides, ["server", "port"]) || 4317

    """
    # ServiceRadar OpenTelemetry Collector Configuration
    # Package ID: #{package.id}
    # Site: #{site}
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    [server]
    bind_address = "0.0.0.0"
    port = #{grpc_port}

    [nats]
    url = "#{nats_url}"
    subject = "events.otel"
    stream = "events"
    timeout_secs = 30
    creds_file = "/etc/serviceradar/creds/nats.creds"

    [nats.tls]
    cert_file = "/etc/serviceradar/certs/collector.pem"
    key_file = "/etc/serviceradar/certs/collector-key.pem"
    ca_file = "/etc/serviceradar/certs/ca-chain.pem"

    [grpc_tls]
    cert_file = "/etc/serviceradar/certs/collector.pem"
    key_file = "/etc/serviceradar/certs/collector-key.pem"
    ca_file = "/etc/serviceradar/certs/ca-chain.pem"
    core_address = "#{core_address}"
    """
  end

  defp generate_trapd_config(package, opts) do
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())
    core_address = Keyword.get(opts, :core_address, default_core_address())
    site = package.site || "default"

    # Apply any config overrides
    listen_addr = get_in(package.config_overrides, ["listen_addr"]) || "0.0.0.0:162"
    grpc_port = get_in(package.config_overrides, ["grpc_port"]) || 50043

    config = %{
      "listen_addr" => listen_addr,
      "nats_url" => nats_url,
      "nats_domain" => "edge",
      "stream_name" => "events",
      "subject" => "snmp.traps",
      "partition" => site,
      "nats_creds_file" => "/etc/serviceradar/creds/nats.creds",
      "nats_security" => %{
        "mode" => "mtls",
        "cert_file" => "/etc/serviceradar/certs/collector.pem",
        "key_file" => "/etc/serviceradar/certs/collector-key.pem",
        "ca_file" => "/etc/serviceradar/certs/ca-chain.pem"
      },
      "grpc_listen_addr" => "0.0.0.0:#{grpc_port}",
      "grpc_security" => %{
        "mode" => "mtls",
        "cert_dir" => "/etc/serviceradar/certs",
        "cert_file" => "/etc/serviceradar/certs/collector.pem",
        "key_file" => "/etc/serviceradar/certs/collector-key.pem",
        "ca_file" => "/etc/serviceradar/certs/ca-chain.pem"
      },
      "core_address" => core_address
    }

    Jason.encode!(config, pretty: true)
  end

  defp generate_netflow_config(package, opts) do
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())
    core_address = Keyword.get(opts, :core_address, default_core_address())
    site = package.site || "default"

    # Apply any config overrides
    listen_addr = get_in(package.config_overrides, ["listen_addr"]) || "0.0.0.0:2055"
    grpc_port = get_in(package.config_overrides, ["grpc_port"]) || 50045

    config = %{
      "listen_addr" => listen_addr,
      "protocols" => ["netflow-v5", "netflow-v9", "ipfix", "sflow"],
      "nats_url" => nats_url,
      "stream_name" => "events",
      "subject" => "events.netflow",
      "partition" => site,
      "nats_creds_file" => "/etc/serviceradar/creds/nats.creds",
      "nats_security" => %{
        "mode" => "mtls",
        "cert_file" => "/etc/serviceradar/certs/collector.pem",
        "key_file" => "/etc/serviceradar/certs/collector-key.pem",
        "ca_file" => "/etc/serviceradar/certs/ca-chain.pem"
      },
      "grpc_listen_addr" => "0.0.0.0:#{grpc_port}",
      "grpc_security" => %{
        "mode" => "mtls",
        "cert_dir" => "/etc/serviceradar/certs",
        "cert_file" => "/etc/serviceradar/certs/collector.pem",
        "key_file" => "/etc/serviceradar/certs/collector-key.pem",
        "ca_file" => "/etc/serviceradar/certs/ca-chain.pem"
      },
      "core_address" => core_address
    }

    Jason.encode!(config, pretty: true)
  end

  defp generate_update_script(package) do
    collector_type = to_string(package.collector_type)
    config_file = config_filename(package)

    """
    #!/bin/bash
    # ServiceRadar Collector Update Script
    # Collector: #{collector_type}
    # Package ID: #{package.id}
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    #
    # This script updates credentials, certificates, and configuration for an
    # already-installed collector service. Install the collector package first.

    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COLLECTOR_TYPE="#{collector_type}"
    SERVICE_NAME="serviceradar-$COLLECTOR_TYPE"
    CONFIG_DIR="/etc/serviceradar"
    CERTS_DIR="$CONFIG_DIR/certs"
    CREDS_DIR="$CONFIG_DIR/creds"

    echo "ServiceRadar Collector Update"
    echo "============================="
    echo "Collector Type: $COLLECTOR_TYPE"
    echo ""

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root (use sudo)"
        exit 1
    fi

    # Check if service exists
    if ! systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        echo "Error: Service $SERVICE_NAME not found."
        echo "Please install the serviceradar-$COLLECTOR_TYPE package first."
        echo ""
        echo "On Debian/Ubuntu:"
        echo "  apt install serviceradar-$COLLECTOR_TYPE"
        echo ""
        echo "On RHEL/CentOS:"
        echo "  dnf install serviceradar-$COLLECTOR_TYPE"
        exit 1
    fi

    echo "Stopping $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME" || true

    echo "Creating directories..."
    mkdir -p "$CERTS_DIR" "$CREDS_DIR" "$CONFIG_DIR/config"

    echo "Installing credentials..."
    cp "$SCRIPT_DIR/creds/nats.creds" "$CREDS_DIR/"
    chmod 600 "$CREDS_DIR/nats.creds"

    echo "Installing certificates..."
    cp "$SCRIPT_DIR/certs/collector.pem" "$CERTS_DIR/"
    cp "$SCRIPT_DIR/certs/collector-key.pem" "$CERTS_DIR/"
    cp "$SCRIPT_DIR/certs/ca-chain.pem" "$CERTS_DIR/"
    chmod 644 "$CERTS_DIR/collector.pem" "$CERTS_DIR/ca-chain.pem"
    chmod 600 "$CERTS_DIR/collector-key.pem"

    echo "Installing configuration..."
    cp "$SCRIPT_DIR/config/#{config_file}" "$CONFIG_DIR/config/"
    chmod 644 "$CONFIG_DIR/config/#{config_file}"

    # Set ownership
    if id -u serviceradar &>/dev/null; then
        chown -R serviceradar:serviceradar "$CONFIG_DIR"
    fi

    echo "Starting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"

    echo ""
    echo "Update complete!"
    echo ""
    echo "Check service status:"
    echo "  systemctl status $SERVICE_NAME"
    echo ""
    echo "View logs:"
    echo "  journalctl -u $SERVICE_NAME -f"
    """
  end

  defp generate_readme(package) do
    collector_type = to_string(package.collector_type)
    config_file = config_filename(package)

    port_info =
      case package.collector_type do
        :flowgger -> "514 (TCP/UDP)"
        :trapd -> "162 (UDP)"
        :netflow -> "2055 (UDP)"
        :otel -> "4317 (gRPC), 4318 (HTTP)"
        _ -> "N/A"
      end

    """
    # ServiceRadar Collector Package

    **Collector Type:** #{collector_type}
    **Package ID:** #{package.id}
    **Site:** #{package.site || "default"}
    **Created:** #{format_datetime(package.inserted_at)}

    ## Prerequisites

    Install the collector package before using this bundle:

    ```bash
    # Debian/Ubuntu
    sudo apt install serviceradar-#{collector_type}

    # RHEL/CentOS
    sudo dnf install serviceradar-#{collector_type}
    ```

    ## Quick Start

    Run the update script to install credentials and configuration:

    ```bash
    sudo ./update.sh
    ```

    ## Contents

    - `creds/nats.creds` - NATS account credentials
    - `certs/collector.pem` - TLS certificate
    - `certs/collector-key.pem` - TLS private key (keep secure!)
    - `certs/ca-chain.pem` - CA certificate chain
    - `config/#{config_file}` - Collector configuration
    - `update.sh` - Update script (copies files, restarts service)

    ## Network Ports

    This collector listens on: #{port_info}

    ## Security Notes

    - The private key and NATS credentials should be kept secure (mode 600)
    - Credentials authenticate this collector to your tenant's NATS account
    - All messages are automatically tagged with your tenant identity
    - mTLS ensures encrypted, authenticated communication

    ## Troubleshooting

    Check collector status and logs:

    ```bash
    # Service status
    systemctl status serviceradar-#{collector_type}

    # View logs
    journalctl -u serviceradar-#{collector_type} -f
    ```

    ## Support

    Documentation: https://docs.serviceradar.cloud
    Issues: https://github.com/carverauto/serviceradar/issues
    """
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp create_tar_gz(files) do
    # Create tarball entries
    entries =
      Enum.map(files, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    # Create the tarball in memory
    case :erl_tar.create({:binary, []}, entries, [:compressed]) do
      {:ok, {:binary, tarball}} -> {:ok, tarball}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "https://app.serviceradar.cloud")
  end

  defp default_nats_url do
    Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats.serviceradar.cloud:4222")
  end

  defp default_core_address do
    Application.get_env(:serviceradar_web_ng, :core_address, "core.serviceradar.cloud:50051")
  end
end
