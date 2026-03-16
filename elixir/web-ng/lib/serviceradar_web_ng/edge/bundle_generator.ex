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
  alias ServiceRadarWebNG.Edge.OnboardingToken
  alias ServiceRadarWebNG.Web.EndpointConfig

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @doc """
  Creates a tarball bundle for the given package and certificate data.

  ## Parameters

    * `package` - The OnboardingPackage struct
    * `bundle_pem` - The decrypted certificate bundle PEM
    * `join_token` - The decrypted join token (reserved for future use)
    * `opts` - Additional options:
      * `:gateway_addr` - Gateway service address (default: from config)

  ## Returns

    * `{:ok, tarball_binary}` - The gzipped tarball as binary
    * `{:error, reason}` - If bundle creation fails

  ## Bootstrap Configuration

  The generated config contains only minimal bootstrap settings:
  - `agent_id` - Component identifier used for gateway enrollment
  - `gateway_addr` - Gateway endpoint
  - `gateway_security` - mTLS credentials

  All monitoring configuration (checks, schedules, etc.) is delivered
  dynamically via the `GetConfig` gRPC call after the component connects.
  """
  @spec create_tarball(OnboardingPackage.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def create_tarball(package, bundle_pem, join_token, opts \\ []) do
    package_dir = "edge-package-#{short_id(package.id)}"

    # Parse the bundle PEM into component parts
    {cert_pem, key_pem, ca_chain_pem} = parse_bundle_pem(bundle_pem)

    # Build the file list for the tarball
    config_yaml = generate_config_yaml(package, join_token, opts)
    config_json = generate_config_json(package, join_token, opts)

    files = [
      {"#{package_dir}/certs/component.pem", cert_pem},
      {"#{package_dir}/certs/component-key.pem", key_pem},
      {"#{package_dir}/certs/ca-chain.pem", ca_chain_pem},
      {"#{package_dir}/config/config.yaml", config_yaml},
      {"#{package_dir}/config/config.json", config_json},
      {"#{package_dir}/install.sh", generate_install_script(package, opts)},
      {"#{package_dir}/README.md", generate_readme(package, opts)}
      | generate_kubernetes_files(
          package_dir,
          package,
          cert_pem,
          key_pem,
          ca_chain_pem,
          join_token,
          opts
        )
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
    component_type = effective_component_type(package.component_type)

    String.trim("""
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    docker run -d --name serviceradar-#{component_type} \\
      -v $(pwd)/certs:/etc/serviceradar/certs:ro \\
      -v $(pwd)/config:/etc/serviceradar/config:ro \\
      ghcr.io/carverauto/serviceradar-#{component_type}:#{image_tag}
    """)
  end

  @doc """
  Generates a one-liner install command for systemd-based systems.
  """
  @spec systemd_install_command(OnboardingPackage.t(), String.t(), keyword()) :: String.t()
  def systemd_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())

    String.trim("""
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    sudo ./install.sh
    """)
  end

  @doc """
  Generates a one-liner install command for Kubernetes.
  """
  @spec kubernetes_install_command(OnboardingPackage.t(), String.t(), keyword()) :: String.t()
  def kubernetes_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    namespace = Keyword.get(opts, :namespace, "serviceradar")

    String.trim("""
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    kubectl apply -f kubernetes/ -n #{namespace}
    """)
  end

  # Private functions

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp parse_bundle_pem(bundle_pem) when is_binary(bundle_pem) do
    # The bundle format from create_with_platform_cert is:
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
    package
    |> build_config_map(join_token, opts)
    |> encode_config_yaml()
  end

  defp generate_config_json(package, _join_token, opts) do
    package
    |> build_config_map(nil, opts)
    |> Jason.encode!(pretty: true)
  end

  defp build_config_map(package, _join_token, opts) do
    component_type = effective_component_type(package.component_type)
    component_id = package.component_id || package.id
    metadata = metadata_map(package)

    base_url = Keyword.get(opts, :base_url, default_base_url())

    gateway_addr =
      Keyword.get(
        opts,
        :gateway_addr,
        Map.get(metadata, "gateway_addr", default_gateway_addr(base_url))
      )

    cert_dir = "/etc/serviceradar/certs"
    partition = Map.get(metadata, "partition", "default")
    host_ip = Map.get(metadata, "host_ip", "PLACEHOLDER_HOST_IP")

    gateway_security = %{
      "mode" => "mtls",
      "cert_dir" => cert_dir,
      "server_name" => gateway_server_name(gateway_addr, metadata, opts),
      "role" => component_type,
      "tls" => %{
        "cert_file" => "component.pem",
        "key_file" => "component-key.pem",
        "ca_file" => "ca-chain.pem",
        "client_ca_file" => "ca-chain.pem"
      }
    }

    config = %{
      "component_type" => component_type,
      "agent_id" => component_id,
      "gateway_addr" => gateway_addr,
      "gateway_security" => gateway_security
    }

    config =
      if component_type == "agent" do
        config
        |> Map.put("partition", partition)
        |> Map.put("host_ip", host_ip)
      else
        config
      end

    config
  end

  defp encode_config_yaml(config) when is_map(config) do
    # Simple but safe YAML encoder for bootstrap config
    config
    |> Enum.map_join("\n", fn
      {key, %{} = value} ->
        "#{key}:\n" <> do_encode_yaml_nested(value, 1)

      {key, value} ->
        "#{key}: #{encode_yaml_value(value)}"
    end)
    |> Kernel.<>("\n")
  end

  defp do_encode_yaml_nested(map, indent) do
    prefix = String.duplicate("  ", indent)

    Enum.map_join(map, "\n", fn
      {key, %{} = value} ->
        "#{prefix}#{key}:\n" <> do_encode_yaml_nested(value, indent + 1)

      {key, value} ->
        "#{prefix}#{key}: #{encode_yaml_value(value)}"
    end)
  end

  defp encode_yaml_value(value) when is_binary(value) do
    # Wrap in double quotes and escape internal quotes
    "\"#{String.replace(value, "\"", "\\\"")}\""
  end

  defp encode_yaml_value(value), do: inspect(value)

  defp sanitize_shell_arg(value) when is_binary(value) do
    String.replace(value, "\"", "-")
  end

  defp sanitize_k8s_label(value) when is_binary(value) do
    # Kubernetes labels must be 63 chars or less and alphanumeric/dash/dot/underscore
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.slice(0, 63)
  end

  defp generate_install_script(package, opts) do
    component_type = effective_component_type(package.component_type)
    enrollment_token = onboarding_token(package, opts)

    # Sanitize for shell interpolation
    s_component_type = sanitize_shell_arg(component_type)
    s_package_id = sanitize_shell_arg(package.id)

    if component_type == "agent" and is_binary(enrollment_token) do
      return_agent_enroll_script(package, enrollment_token)
    else
      String.trim("""
      #!/bin/bash
      # ServiceRadar Edge Component Installer
      # Component: #{s_component_type}
      # Package ID: #{s_package_id}
      # Generated: #{DateTime.to_iso8601(DateTime.utc_now())}

      set -e

      SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      COMPONENT_TYPE="#{s_component_type}"
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
      """)
    end
  end

  defp generate_readme(package, opts) do
    component_type = effective_component_type(package.component_type)
    enrollment_token = onboarding_token(package, opts)

    """
    # ServiceRadar Edge Package

    **Component Type:** #{component_type}
    **Package ID:** #{package.id}
    **Created:** #{format_datetime(package.created_at)}

    ## Architecture

    This package contains a **minimal bootstrap configuration**. The component connects
    to the ServiceRadar gateway using mTLS, then receives all monitoring configuration
    dynamically via the `GetConfig` gRPC call.

    **Bootstrap config includes:**
    - Gateway endpoint address
    - mTLS certificates for secure connection
    - Both `config.yaml` and `config.json` (same content for YAML/JSON parsers)

    **Delivered via GetConfig:**
    - Monitoring checks and schedules
    - Sweep configurations
    - Deployment-specific settings

    #{quick_start_section(component_type, enrollment_token)}

    ## Contents

    - `certs/component.pem` - Component TLS certificate
    - `certs/component-key.pem` - Component private key (keep secure!)
    - `certs/ca-chain.pem` - CA certificate chain for verification
    - `config/config.yaml` - Minimal bootstrap configuration
    - `install.sh` - Automated installer script
    - `kubernetes/` - Kubernetes manifests for k8s deployment

    ## Security Notes

    - The private key (`component-key.pem`) should be kept secure
    - Certificates are valid for 365 days from creation
    - All connections use mTLS (mutual TLS) for authentication

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

  @sobelow_skip ["Traversal.FileModule"]
  defp create_tar_gz(files) do
    # Create tarball entries
    entries =
      Enum.map(files, fn {name, content} ->
        data =
          case content do
            nil -> ""
            _ -> IO.iodata_to_binary(content)
          end

        {String.to_charlist(name), data}
      end)

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-bundle-#{:erlang.unique_integer([:positive])}.tar.gz"
      )

    try do
      case :erl_tar.create(String.to_charlist(tmp_path), entries, [:compressed]) do
        :ok ->
          case File.read(tmp_path) do
            {:ok, tarball} -> {:ok, tarball}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    after
      _ = File.rm(tmp_path)
    end
  end

  # Kubernetes manifest generation

  defp generate_kubernetes_files(package_dir, package, cert_pem, key_pem, ca_chain_pem, join_token, opts) do
    namespace = Keyword.get(opts, :namespace, "serviceradar")
    image_tag = Keyword.get(opts, :image_tag, "latest")

    [
      {"#{package_dir}/kubernetes/namespace.yaml", generate_k8s_namespace(namespace)},
      {"#{package_dir}/kubernetes/secret.yaml", generate_k8s_secret(package, cert_pem, key_pem, ca_chain_pem, namespace)},
      {"#{package_dir}/kubernetes/configmap.yaml", generate_k8s_configmap(package, join_token, namespace, opts)},
      {"#{package_dir}/kubernetes/deployment.yaml", generate_k8s_deployment(package, namespace, image_tag)},
      {"#{package_dir}/kubernetes/kustomization.yaml", generate_k8s_kustomization()}
    ]
  end

  defp generate_k8s_namespace(namespace) do
    """
    # ServiceRadar Edge Component - Namespace
    # Apply with: kubectl apply -f namespace.yaml
    apiVersion: v1
    kind: Namespace
    metadata:
      name: #{namespace}
      labels:
        app.kubernetes.io/part-of: serviceradar
    """
  end

  defp generate_k8s_secret(package, cert_pem, key_pem, ca_chain_pem, namespace) do
    component_type = effective_component_type(package.component_type)
    component_id = package.component_id || package.id

    s_component_type = sanitize_k8s_label(component_type)
    s_component_id = sanitize_k8s_label(component_id)

    # Base64 encode the certificate data
    cert_b64 = Base.encode64(cert_pem)
    key_b64 = Base.encode64(key_pem)
    ca_b64 = Base.encode64(ca_chain_pem)

    """
    # ServiceRadar Edge Component - TLS Certificates
    # Contains mTLS certificates for secure communication
    apiVersion: v1
    kind: Secret
    metadata:
      name: serviceradar-#{s_component_type}-tls
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{s_component_type}
        app.kubernetes.io/component: #{s_component_type}
        app.kubernetes.io/part-of: serviceradar
        serviceradar.io/component-id: "#{s_component_id}"
    type: kubernetes.io/tls
    data:
      tls.crt: #{cert_b64}
      tls.key: #{key_b64}
      ca.crt: #{ca_b64}
    """
  end

  defp generate_k8s_configmap(package, _join_token, namespace, opts) do
    component_type = effective_component_type(package.component_type)
    component_id = package.component_id || package.id

    s_component_type = sanitize_k8s_label(component_type)
    s_component_id = sanitize_k8s_label(component_id)

    # Minimal bootstrap config - monitoring settings delivered via GetConfig
    config_yaml = generate_config_yaml(package, nil, opts)
    config_json = generate_config_json(package, nil, opts)

    config_b64 = Base.encode64(config_yaml)
    config_json_b64 = Base.encode64(config_json)

    """
    # ServiceRadar Edge Component - Configuration
    # Note: This is a minimal bootstrap config. All monitoring configuration
    # (checks, schedules, etc.) is delivered via GetConfig after connection.
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: serviceradar-#{s_component_type}-config
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{s_component_type}
        app.kubernetes.io/component: #{s_component_type}
        app.kubernetes.io/part-of: serviceradar
        serviceradar.io/component-id: "#{s_component_id}"
    binaryData:
      config.yaml: #{config_b64}
      config.json: #{config_json_b64}
    """
  end

  defp generate_k8s_deployment(package, namespace, image_tag) do
    component_type = effective_component_type(package.component_type)
    component_id = package.component_id || package.id
    grpc_port = grpc_port_for_component(component_type)

    s_component_type = sanitize_k8s_label(component_type)
    s_component_id = sanitize_k8s_label(component_id)

    """
    # ServiceRadar Edge Component - Deployment
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: serviceradar-#{s_component_type}
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{s_component_type}
        app.kubernetes.io/component: #{s_component_type}
        app.kubernetes.io/part-of: serviceradar
        serviceradar.io/component-id: "#{s_component_id}"
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: serviceradar-#{s_component_type}
      template:
        metadata:
          labels:
            app.kubernetes.io/name: serviceradar-#{s_component_type}
            app.kubernetes.io/component: #{s_component_type}
            app.kubernetes.io/part-of: serviceradar
        spec:
          serviceAccountName: serviceradar-#{s_component_type}
          containers:
            - name: #{s_component_type}
              image: ghcr.io/carverauto/serviceradar-#{s_component_type}:#{image_tag}
              args:
                - --config
                - /etc/serviceradar/config/config.yaml
              ports:
                - name: grpc
                  containerPort: #{grpc_port}
                  protocol: TCP
                - name: metrics
                  containerPort: 9090
                  protocol: TCP
              env:
                - name: SERVICERADAR_COMPONENT_ID
                  value: "#{s_component_id}"
                - name: SERVICERADAR_LOG_LEVEL
                  value: "info"
              volumeMounts:
                - name: tls-certs
                  mountPath: /etc/serviceradar/certs
                  readOnly: true
                - name: config
                  mountPath: /etc/serviceradar/config
                  readOnly: true
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
              livenessProbe:
                grpc:
                  port: #{grpc_port}
                initialDelaySeconds: 10
                periodSeconds: 30
              readinessProbe:
                grpc:
                  port: #{grpc_port}
                initialDelaySeconds: 5
                periodSeconds: 10
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                runAsUser: 1000
                capabilities:
                  drop:
                    - ALL
          volumes:
            - name: tls-certs
              secret:
                secretName: serviceradar-#{s_component_type}-tls
            - name: config
              configMap:
                name: serviceradar-#{s_component_type}-config
          securityContext:
            fsGroup: 1000
    ---
    # ServiceAccount for the component
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: serviceradar-#{s_component_type}
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{s_component_type}
        app.kubernetes.io/part-of: serviceradar
    """
  end

  defp generate_k8s_kustomization do
    """
    # Kustomization file for easy deployment
    # Apply with: kubectl apply -k kubernetes/
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization

    resources:
      - namespace.yaml
      - secret.yaml
      - configmap.yaml
      - deployment.yaml
    """
  end

  defp default_base_url do
    EndpointConfig.base_url()
  end

  defp default_gateway_addr(base_url) do
    env_gateway_addr = Application.get_env(:serviceradar_web_ng, :gateway_addr)

    case normalize_string(env_gateway_addr) do
      nil ->
        derive_gateway_addr(base_url) || "agent-gateway:50052"

      gateway_addr ->
        gateway_addr
    end
  end

  defp onboarding_token(package, opts) do
    download_token = Keyword.get(opts, :download_token)
    base_url = Keyword.get(opts, :base_url, default_base_url())

    if is_binary(download_token) and download_token != "" do
      case OnboardingToken.encode(package.id, download_token, base_url) do
        {:ok, token} -> token
        _ -> nil
      end
    end
  end

  defp return_agent_enroll_script(package, token) do
    s_package_id = sanitize_shell_arg(package.id)
    s_token = sanitize_shell_arg(token)

    String.trim("""
    #!/bin/bash
    # ServiceRadar Agent Enrollment
    # Package ID: #{s_package_id}
    # Generated: #{DateTime.to_iso8601(DateTime.utc_now())}

    set -e

    echo "Enrolling ServiceRadar agent..."
    /usr/local/bin/serviceradar-cli enroll --token "#{s_token}"

    echo ""
    echo "Enrollment complete."
    """)
  end

  defp quick_start_section("agent", token) when is_binary(token) do
    """
    ## Quick Start

    Enroll the agent with the onboarding token (no config edits required):

    ```bash
    /usr/local/bin/serviceradar-cli enroll --token #{token}
    ```
    """
  end

  defp quick_start_section(component_type, _token) do
    """
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

    ### Kubernetes

    ```bash
    kubectl apply -k kubernetes/
    ```

    Or apply individual manifests:

    ```bash
    kubectl apply -f kubernetes/namespace.yaml
    kubectl apply -f kubernetes/secret.yaml
    kubectl apply -f kubernetes/configmap.yaml
    kubectl apply -f kubernetes/deployment.yaml
    ```
    """
  end

  defp metadata_map(%OnboardingPackage{metadata_json: metadata_json})
       when is_binary(metadata_json) and metadata_json != "" do
    case Jason.decode(metadata_json) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp metadata_map(_), do: %{}

  defp gateway_server_name(gateway_addr, metadata, opts) when is_binary(gateway_addr) do
    override =
      normalize_string(Keyword.get(opts, :gateway_server_name)) ||
        normalize_string(Map.get(metadata, "gateway_server_name")) ||
        normalize_string(Application.get_env(:serviceradar_web_ng, :gateway_server_name))

    if is_binary(override) do
      override
    else
      host = gateway_host(gateway_addr)

      if internal_gateway_host?(host) do
        host
      else
        "serviceradar-agent-gateway"
      end
    end
  end

  defp gateway_host(gateway_addr) do
    case String.split(gateway_addr, ":") do
      [host, _port] -> host
      [host] -> host
      _ -> gateway_addr
    end
  end

  defp internal_gateway_host?(host) when is_binary(host) do
    host in [
      "serviceradar-agent-gateway",
      "agent-gateway",
      "agent-gateway.serviceradar"
    ] or String.ends_with?(host, ".svc.cluster.local")
  end

  defp internal_gateway_host?(_), do: false

  defp derive_gateway_addr(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) ->
        host
        |> derive_gateway_host()
        |> case do
          nil -> nil
          derived_host -> "#{derived_host}:50052"
        end

      _ ->
        nil
    end
  end

  defp derive_gateway_addr(_), do: nil

  defp derive_gateway_host(host) when is_binary(host) do
    host = String.trim(host)

    cond do
      host == "" ->
        nil

      String.contains?(host, "-gw.") or String.ends_with?(host, "-gw") ->
        host

      true ->
        case String.split(host, ".", parts: 2) do
          [first, rest] when rest != "" -> "#{first}-gw.#{rest}"
          [single] -> "#{single}-gw"
          _ -> host
        end
    end
  end

  defp derive_gateway_host(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil

  defp grpc_port_for_component(_), do: 50_051

  defp effective_component_type(component_type) do
    case to_string(component_type) do
      "sync" -> "agent"
      other -> other
    end
  end
end
