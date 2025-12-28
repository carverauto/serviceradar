defmodule ServiceRadarWebNG.Edge.BundleGenerator do
  @moduledoc """
  Generates downloadable installation bundles for edge components.

  A bundle contains everything needed to deploy an edge component:
  - Certificates (component cert, private key, CA chain)
  - Configuration file
  - Platform-detecting install script

  ## Bundle Structure

      edge-package-<id>/
      ├── certs/
      │   ├── component.pem        # Component certificate
      │   ├── component-key.pem    # Private key
      │   └── ca-chain.pem         # Root + intermediate CA chain
      ├── config/
      │   └── config.yaml          # Component configuration
      └── install.sh               # Platform-detecting installer

  """

  alias ServiceRadar.Edge.OnboardingPackage

  @doc """
  Creates a tarball bundle for the given package and certificate data.

  ## Parameters

    * `package` - The OnboardingPackage struct
    * `bundle_pem` - The decrypted certificate bundle PEM
    * `join_token` - The decrypted join token
    * `opts` - Additional options:
      * `:core_address` - Core service address (default: from config)
      * `:nats_url` - NATS server URL (default: from config)

  ## Returns

    * `{:ok, tarball_binary}` - The gzipped tarball as binary
    * `{:error, reason}` - If bundle creation fails

  """
  @spec create_tarball(OnboardingPackage.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def create_tarball(package, bundle_pem, join_token, opts \\ []) do
    package_dir = "edge-package-#{short_id(package.id)}"

    # Parse the bundle PEM into component parts
    {cert_pem, key_pem, ca_chain_pem} = parse_bundle_pem(bundle_pem)

    # Build the file list for the tarball
    files = [
      {"#{package_dir}/certs/component.pem", cert_pem},
      {"#{package_dir}/certs/component-key.pem", key_pem},
      {"#{package_dir}/certs/ca-chain.pem", ca_chain_pem},
      {"#{package_dir}/config/config.yaml", generate_config_yaml(package, join_token, opts)},
      {"#{package_dir}/install.sh", generate_install_script(package, opts)},
      {"#{package_dir}/README.md", generate_readme(package)}
    ]

    # Create the tarball
    create_tar_gz(files)
  end

  @doc """
  Returns the bundle filename for a package.
  """
  @spec bundle_filename(OnboardingPackage.t()) :: String.t()
  def bundle_filename(package) do
    "edge-package-#{short_id(package.id)}.tar.gz"
  end

  @doc """
  Generates a one-liner install command for Docker.
  """
  @spec docker_install_command(OnboardingPackage.t(), String.t(), keyword()) :: String.t()
  def docker_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    image_tag = Keyword.get(opts, :image_tag, "latest")

    """
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    docker run -d --name serviceradar-#{package.component_type} \\
      -v $(pwd)/certs:/etc/serviceradar/certs:ro \\
      -v $(pwd)/config:/etc/serviceradar/config:ro \\
      ghcr.io/carverauto/serviceradar-#{package.component_type}:#{image_tag}
    """
    |> String.trim()
  end

  @doc """
  Generates a one-liner install command for systemd-based systems.
  """
  @spec systemd_install_command(OnboardingPackage.t(), String.t(), keyword()) :: String.t()
  def systemd_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())

    """
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    sudo ./install.sh
    """
    |> String.trim()
  end

  # Private functions

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp parse_bundle_pem(bundle_pem) when is_binary(bundle_pem) do
    # The bundle format from create_with_tenant_cert is:
    # # Component Certificate
    # -----BEGIN CERTIFICATE-----
    # ...
    # -----END CERTIFICATE-----
    # # Component Private Key
    # -----BEGIN RSA PRIVATE KEY-----
    # ...
    # -----END RSA PRIVATE KEY-----
    # # CA Chain
    # -----BEGIN CERTIFICATE-----
    # ...

    parts =
      bundle_pem
      |> String.split(~r/# (?:Component Certificate|Component Private Key|CA Chain)\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case parts do
      [cert, key, chain] -> {cert, key, chain}
      [cert, key] -> {cert, key, ""}
      _ -> {bundle_pem, "", ""}
    end
  end

  defp parse_bundle_pem(_), do: {"", "", ""}

  defp generate_config_yaml(package, join_token, opts) do
    core_address = Keyword.get(opts, :core_address, default_core_address())
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())

    component_type = to_string(package.component_type)

    config = %{
      "component_id" => package.component_id || package.id,
      "component_type" => component_type,
      "join_token" => join_token,
      "core" => %{
        "address" => core_address
      },
      "nats" => %{
        "url" => nats_url
      },
      "tls" => %{
        "cert_file" => "/etc/serviceradar/certs/component.pem",
        "key_file" => "/etc/serviceradar/certs/component-key.pem",
        "ca_file" => "/etc/serviceradar/certs/ca-chain.pem"
      }
    }

    # Add component-specific config
    config =
      case package.component_type do
        :poller ->
          Map.put(config, "poller", %{
            "partition_id" => package.site || "default"
          })

        :agent ->
          Map.put(config, "agent", %{
            "poller_id" => package.poller_id
          })

        :checker ->
          config
          |> Map.put("checker", %{
            "kind" => package.checker_kind,
            "config" => package.checker_config_json || %{}
          })

        _ ->
          config
      end

    # Convert to YAML
    encode_yaml(config)
  end

  defp generate_install_script(package, _opts) do
    component_type = to_string(package.component_type)

    """
    #!/bin/bash
    # ServiceRadar Edge Component Installer
    # Component: #{component_type}
    # Package ID: #{package.id}
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COMPONENT_TYPE="#{component_type}"
    INSTALL_DIR="/opt/serviceradar"
    CONFIG_DIR="/etc/serviceradar"
    CERT_DIR="$CONFIG_DIR/certs"

    echo "ServiceRadar Edge Component Installer"
    echo "======================================"
    echo "Component Type: $COMPONENT_TYPE"
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
        mkdir -p "$CONFIG_DIR" "$CERT_DIR"

        # Copy certificates
        cp "$SCRIPT_DIR/certs/"* "$CERT_DIR/"
        chmod 600 "$CERT_DIR/component-key.pem"
        chmod 644 "$CERT_DIR/component.pem" "$CERT_DIR/ca-chain.pem"

        # Copy config
        cp "$SCRIPT_DIR/config/config.yaml" "$CONFIG_DIR/"

        # Run container
        docker run -d \\
            --name "serviceradar-$COMPONENT_TYPE" \\
            --restart unless-stopped \\
            -v "$CERT_DIR:/etc/serviceradar/certs:ro" \\
            -v "$CONFIG_DIR:/etc/serviceradar/config:ro" \\
            "ghcr.io/carverauto/serviceradar-$COMPONENT_TYPE:latest"

        echo ""
        echo "Container started. Check status with:"
        echo "  docker logs serviceradar-$COMPONENT_TYPE"
    }

    install_systemd() {
        echo "Installing via systemd..."

        # Create directories
        sudo mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CERT_DIR"

        # Copy certificates
        sudo cp "$SCRIPT_DIR/certs/"* "$CERT_DIR/"
        sudo chmod 600 "$CERT_DIR/component-key.pem"
        sudo chmod 644 "$CERT_DIR/component.pem" "$CERT_DIR/ca-chain.pem"

        # Copy config
        sudo cp "$SCRIPT_DIR/config/config.yaml" "$CONFIG_DIR/"

        # Download binary if not present
        if [ ! -f "$INSTALL_DIR/serviceradar-$COMPONENT_TYPE" ]; then
            echo "Binary not found. Please download serviceradar-$COMPONENT_TYPE to $INSTALL_DIR/"
            echo "Or use Docker installation instead."
            exit 1
        fi

        # Create systemd service
        cat << EOF | sudo tee "/etc/systemd/system/serviceradar-$COMPONENT_TYPE.service"
    [Unit]
    Description=ServiceRadar $COMPONENT_TYPE
    After=network.target

    [Service]
    Type=simple
    ExecStart=$INSTALL_DIR/serviceradar-$COMPONENT_TYPE --config $CONFIG_DIR/config.yaml
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
        sudo chown -R serviceradar:serviceradar "$CONFIG_DIR" "$CERT_DIR"

        # Enable and start service
        sudo systemctl daemon-reload
        sudo systemctl enable "serviceradar-$COMPONENT_TYPE"
        sudo systemctl start "serviceradar-$COMPONENT_TYPE"

        echo ""
        echo "Service started. Check status with:"
        echo "  sudo systemctl status serviceradar-$COMPONENT_TYPE"
    }

    show_manual_instructions() {
        echo ""
        echo "Manual Installation"
        echo "==================="
        echo ""
        echo "1. Copy certificates to $CERT_DIR/"
        echo "   cp $SCRIPT_DIR/certs/* $CERT_DIR/"
        echo ""
        echo "2. Copy config to $CONFIG_DIR/"
        echo "   cp $SCRIPT_DIR/config/config.yaml $CONFIG_DIR/"
        echo ""
        echo "3. Download and run the serviceradar-$COMPONENT_TYPE binary"
        echo "   serviceradar-$COMPONENT_TYPE --config $CONFIG_DIR/config.yaml"
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
    component_type = to_string(package.component_type)

    """
    # ServiceRadar Edge Package

    **Component Type:** #{component_type}
    **Package ID:** #{package.id}
    **Created:** #{format_datetime(package.created_at)}

    ## Quick Start

    ### Docker (Recommended)

    ```bash
    ./install.sh
    ```

    Or manually:

    ```bash
    docker run -d --name serviceradar-#{component_type} \\
      -v $(pwd)/certs:/etc/serviceradar/certs:ro \\
      -v $(pwd)/config:/etc/serviceradar/config:ro \\
      ghcr.io/carverauto/serviceradar-#{component_type}:latest
    ```

    ### systemd

    ```bash
    sudo ./install.sh
    ```

    ## Contents

    - `certs/component.pem` - Component TLS certificate
    - `certs/component-key.pem` - Component private key (keep secure!)
    - `certs/ca-chain.pem` - CA certificate chain for verification
    - `config/config.yaml` - Component configuration
    - `install.sh` - Automated installer script

    ## Security Notes

    - The private key (`component-key.pem`) should be kept secure
    - Certificates are valid for 365 days from creation
    - The join token expires after 24 hours

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
    # Simple YAML encoder for our config structure
    # For production, consider using a proper YAML library
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
      # Simple list encoding
      "[" <> Enum.map_join(value, ", ", &inspect/1) <> "]"
    end
  end

  defp default_base_url do
    Application.get_env(:serviceradar_web_ng, :base_url, "https://app.serviceradar.cloud")
  end

  defp default_core_address do
    Application.get_env(:serviceradar_web_ng, :core_address, "core.serviceradar.cloud:50052")
  end

  defp default_nats_url do
    Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats.serviceradar.cloud:4222")
  end
end
