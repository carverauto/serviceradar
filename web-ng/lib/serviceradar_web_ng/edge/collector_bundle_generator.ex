defmodule ServiceRadarWebNG.Edge.CollectorBundleGenerator do
  @moduledoc """
  Generates downloadable installation bundles for collector edge components.

  A collector bundle contains everything needed to deploy a collector:
  - NATS credentials file (.creds) for tenant-isolated messaging
  - Collector configuration file
  - Installation script

  ## Bundle Structure

      collector-package-<id>/
      ├── nats.creds           # NATS account credentials
      ├── config/
      │   └── config.yaml      # Collector configuration
      ├── install.sh           # Platform-detecting installer
      └── README.md            # Installation instructions

  ## Future: mTLS Certificates

  For collectors that need mTLS (e.g., for gRPC endpoints), the bundle
  can optionally include:
  - certs/collector.pem
  - certs/collector-key.pem
  - certs/ca-chain.pem
  """

  alias ServiceRadar.Edge.CollectorPackage

  @doc """
  Creates a tarball bundle for the given collector package.

  ## Parameters

    * `package` - The CollectorPackage struct
    * `nats_creds` - The decrypted NATS credentials content
    * `opts` - Additional options:
      * `:nats_url` - NATS server URL (default: from config)
      * `:core_address` - Core service address (default: from config)

  ## Returns

    * `{:ok, tarball_binary}` - The gzipped tarball as binary
    * `{:error, reason}` - If bundle creation fails
  """
  @spec create_tarball(CollectorPackage.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def create_tarball(package, nats_creds, opts \\ []) do
    package_dir = "collector-package-#{short_id(package.id)}"

    # Build the file list for the tarball
    files = [
      {"#{package_dir}/nats.creds", nats_creds},
      {"#{package_dir}/config/config.yaml", generate_config_yaml(package, opts)},
      {"#{package_dir}/install.sh", generate_install_script(package, opts)},
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
  Generates a one-liner install command for Docker.
  """
  @spec docker_install_command(CollectorPackage.t(), String.t(), keyword()) :: String.t()
  def docker_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    image_tag = Keyword.get(opts, :image_tag, "latest")
    collector_type = to_string(package.collector_type)

    """
    curl -fsSL "#{base_url}/api/admin/collectors/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd collector-package-#{short_id(package.id)} && \\
    docker run -d --name serviceradar-#{collector_type} \\
      -v $(pwd)/nats.creds:/etc/serviceradar/creds/nats.creds:ro \\
      -v $(pwd)/config:/etc/serviceradar/config:ro \\
      ghcr.io/carverauto/serviceradar-#{collector_type}:#{image_tag}
    """
    |> String.trim()
  end

  @doc """
  Generates a one-liner install command for systemd-based systems.
  """
  @spec systemd_install_command(CollectorPackage.t(), String.t(), keyword()) :: String.t()
  def systemd_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())

    """
    curl -fsSL "#{base_url}/api/admin/collectors/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd collector-package-#{short_id(package.id)} && \\
    sudo ./install.sh
    """
    |> String.trim()
  end

  # Private functions

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp generate_config_yaml(package, opts) do
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())
    collector_type = to_string(package.collector_type)

    # Base config common to all collectors
    config = %{
      "collector_id" => package.id,
      "collector_type" => collector_type,
      "site" => package.site || "default",
      "hostname" => package.hostname,
      "nats" => %{
        "url" => nats_url,
        "creds_file" => "/etc/serviceradar/creds/nats.creds"
      }
    }

    # Add collector-specific configuration
    config = add_collector_specific_config(config, package)

    # Merge any overrides
    config =
      if package.config_overrides && map_size(package.config_overrides) > 0 do
        deep_merge(config, package.config_overrides)
      else
        config
      end

    encode_yaml(config)
  end

  defp add_collector_specific_config(config, package) do
    case package.collector_type do
      :flowgger ->
        Map.merge(config, %{
          "flowgger" => %{
            "listen" => "0.0.0.0:514",
            "protocol" => "syslog",
            "format" => "rfc5424"
          }
        })

      :trapd ->
        Map.merge(config, %{
          "trapd" => %{
            "listen" => "0.0.0.0:162",
            "community" => "public",
            "v3_enabled" => false
          }
        })

      :netflow ->
        Map.merge(config, %{
          "netflow" => %{
            "listen" => "0.0.0.0:2055",
            "protocols" => ["netflow-v5", "netflow-v9", "ipfix", "sflow"]
          }
        })

      :otel ->
        Map.merge(config, %{
          "otel" => %{
            "grpc_listen" => "0.0.0.0:4317",
            "http_listen" => "0.0.0.0:4318"
          }
        })

      _ ->
        config
    end
  end

  defp generate_install_script(package, _opts) do
    collector_type = to_string(package.collector_type)

    """
    #!/bin/bash
    # ServiceRadar Collector Installer
    # Collector: #{collector_type}
    # Package ID: #{package.id}
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COLLECTOR_TYPE="#{collector_type}"
    INSTALL_DIR="/opt/serviceradar"
    CONFIG_DIR="/etc/serviceradar"
    CREDS_DIR="$CONFIG_DIR/creds"

    echo "ServiceRadar Collector Installer"
    echo "================================="
    echo "Collector Type: $COLLECTOR_TYPE"
    echo ""

    # Detect platform
    detect_platform() {
        if command -v docker &> /dev/null && docker info &> /dev/null; then
            echo "docker"
        elif command -v podman &> /dev/null; then
            echo "podman"
        elif systemctl --version &> /dev/null 2>&1; then
            echo "systemd"
        else
            echo "manual"
        fi
    }

    PLATFORM=$(detect_platform)
    echo "Detected platform: $PLATFORM"
    echo ""

    install_docker() {
        echo "Installing via Docker..."

        # Create directories
        mkdir -p "$CONFIG_DIR" "$CREDS_DIR"

        # Copy NATS credentials
        cp "$SCRIPT_DIR/nats.creds" "$CREDS_DIR/"
        chmod 600 "$CREDS_DIR/nats.creds"

        # Copy config
        mkdir -p "$CONFIG_DIR/config"
        cp "$SCRIPT_DIR/config/config.yaml" "$CONFIG_DIR/config/"

        # Determine ports based on collector type
        PORTS=""
        case "$COLLECTOR_TYPE" in
            flowgger)
                PORTS="-p 514:514/udp -p 514:514/tcp"
                ;;
            trapd)
                PORTS="-p 162:162/udp"
                ;;
            netflow)
                PORTS="-p 2055:2055/udp"
                ;;
            otel)
                PORTS="-p 4317:4317 -p 4318:4318"
                ;;
        esac

        # Run container
        docker run -d \\
            --name "serviceradar-$COLLECTOR_TYPE" \\
            --restart unless-stopped \\
            $PORTS \\
            -v "$CREDS_DIR/nats.creds:/etc/serviceradar/creds/nats.creds:ro" \\
            -v "$CONFIG_DIR/config:/etc/serviceradar/config:ro" \\
            "ghcr.io/carverauto/serviceradar-$COLLECTOR_TYPE:latest"

        echo ""
        echo "Container started. Check status with:"
        echo "  docker logs serviceradar-$COLLECTOR_TYPE"
    }

    install_systemd() {
        echo "Installing via systemd..."

        # Create directories
        sudo mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CREDS_DIR"

        # Copy NATS credentials
        sudo cp "$SCRIPT_DIR/nats.creds" "$CREDS_DIR/"
        sudo chmod 600 "$CREDS_DIR/nats.creds"

        # Copy config
        sudo mkdir -p "$CONFIG_DIR/config"
        sudo cp "$SCRIPT_DIR/config/config.yaml" "$CONFIG_DIR/config/"

        # Check for binary
        if [ ! -f "$INSTALL_DIR/serviceradar-$COLLECTOR_TYPE" ]; then
            echo "Binary not found. Please download serviceradar-$COLLECTOR_TYPE to $INSTALL_DIR/"
            echo "Or use Docker installation instead."
            exit 1
        fi

        # Create systemd service
        cat << EOF | sudo tee "/etc/systemd/system/serviceradar-$COLLECTOR_TYPE.service"
    [Unit]
    Description=ServiceRadar $COLLECTOR_TYPE Collector
    After=network.target

    [Service]
    Type=simple
    ExecStart=$INSTALL_DIR/serviceradar-$COLLECTOR_TYPE --config $CONFIG_DIR/config/config.yaml
    Restart=always
    RestartSec=5
    User=serviceradar

    [Install]
    WantedBy=multi-user.target
    EOF

        # Create user if needed
        if ! id -u serviceradar &>/dev/null; then
            sudo useradd -r -s /bin/false serviceradar
        fi

        # Set permissions
        sudo chown -R serviceradar:serviceradar "$CONFIG_DIR" "$CREDS_DIR"

        # Enable and start service
        sudo systemctl daemon-reload
        sudo systemctl enable "serviceradar-$COLLECTOR_TYPE"
        sudo systemctl start "serviceradar-$COLLECTOR_TYPE"

        echo ""
        echo "Service started. Check status with:"
        echo "  sudo systemctl status serviceradar-$COLLECTOR_TYPE"
    }

    show_manual_instructions() {
        echo ""
        echo "Manual Installation"
        echo "==================="
        echo ""
        echo "1. Copy NATS credentials to $CREDS_DIR/"
        echo "   cp $SCRIPT_DIR/nats.creds $CREDS_DIR/"
        echo ""
        echo "2. Copy config to $CONFIG_DIR/config/"
        echo "   cp -r $SCRIPT_DIR/config $CONFIG_DIR/"
        echo ""
        echo "3. Download and run the serviceradar-$COLLECTOR_TYPE binary"
        echo "   serviceradar-$COLLECTOR_TYPE --config $CONFIG_DIR/config/config.yaml"
        echo ""
    }

    # Main installation logic
    case "$PLATFORM" in
        docker|podman)
            install_docker
            ;;
        systemd)
            read -p "Install as systemd service? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_systemd
            else
                show_manual_instructions
            fi
            ;;
        *)
            show_manual_instructions
            ;;
    esac

    echo ""
    echo "Installation complete!"
    """
  end

  defp generate_readme(package) do
    collector_type = to_string(package.collector_type)

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

    ## Quick Start

    ### Docker (Recommended)

    ```bash
    ./install.sh
    ```

    Or manually:

    ```bash
    docker run -d --name serviceradar-#{collector_type} \\
      -p #{port_info |> String.split(",") |> List.first() |> String.trim()} \\
      -v $(pwd)/nats.creds:/etc/serviceradar/creds/nats.creds:ro \\
      -v $(pwd)/config:/etc/serviceradar/config:ro \\
      ghcr.io/carverauto/serviceradar-#{collector_type}:latest
    ```

    ### systemd

    ```bash
    sudo ./install.sh
    ```

    ## Contents

    - `nats.creds` - NATS account credentials for tenant-isolated messaging
    - `config/config.yaml` - Collector configuration
    - `install.sh` - Automated installer script

    ## Network Ports

    This collector listens on: #{port_info}

    ## Security Notes

    - The NATS credentials file should be kept secure (mode 600)
    - Credentials authenticate this collector to your tenant's NATS account
    - All messages are automatically tagged with your tenant identity

    ## Troubleshooting

    Check collector logs:
    ```bash
    # Docker
    docker logs serviceradar-#{collector_type}

    # systemd
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

  defp encode_yaml(map) do
    do_encode_yaml(map, 0)
  end

  defp do_encode_yaml(map, indent) when is_map(map) do
    prefix = String.duplicate("  ", indent)

    Enum.map_join(map, "\n", fn {key, value} ->
      "#{prefix}#{key}: #{encode_yaml_value(value, indent)}"
    end)
  end

  defp encode_yaml_value(value, _indent) when is_binary(value), do: "\"#{value}\""
  defp encode_yaml_value(value, _indent) when is_number(value), do: to_string(value)
  defp encode_yaml_value(value, _indent) when is_boolean(value), do: to_string(value)
  defp encode_yaml_value(value, _indent) when is_nil(value), do: "null"

  defp encode_yaml_value(value, indent) when is_map(value) do
    if map_size(value) == 0 do
      "{}"
    else
      "\n" <> do_encode_yaml(value, indent + 1)
    end
  end

  defp encode_yaml_value(value, _indent) when is_list(value) do
    if value == [] do
      "[]"
    else
      "[" <> Enum.map_join(value, ", ", &inspect/1) <> "]"
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp default_base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "https://app.serviceradar.cloud")
  end

  defp default_nats_url do
    Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats.serviceradar.cloud:4222")
  end
end
