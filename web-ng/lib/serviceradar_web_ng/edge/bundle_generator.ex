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

  @doc """
  Generates a one-liner install command for Kubernetes.
  """
  @spec kubernetes_install_command(OnboardingPackage.t(), String.t(), keyword()) :: String.t()
  def kubernetes_install_command(package, download_token, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    namespace = Keyword.get(opts, :namespace, "serviceradar")

    """
    curl -fsSL "#{base_url}/api/edge-packages/#{package.id}/bundle?token=#{download_token}" | tar xzf - && \\
    cd edge-package-#{short_id(package.id)} && \\
    kubectl apply -f kubernetes/ -n #{namespace}
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

    ## Contents

    - `certs/component.pem` - Component TLS certificate
    - `certs/component-key.pem` - Component private key (keep secure!)
    - `certs/ca-chain.pem` - CA certificate chain for verification
    - `config/config.yaml` - Component configuration
    - `install.sh` - Automated installer script
    - `kubernetes/` - Kubernetes manifests for k8s deployment

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

  # Kubernetes manifest generation

  defp generate_kubernetes_files(
         package_dir,
         package,
         cert_pem,
         key_pem,
         ca_chain_pem,
         join_token,
         opts
       ) do
    namespace = Keyword.get(opts, :namespace, "serviceradar")
    image_tag = Keyword.get(opts, :image_tag, "latest")

    [
      {"#{package_dir}/kubernetes/namespace.yaml", generate_k8s_namespace(namespace)},
      {"#{package_dir}/kubernetes/secret.yaml",
       generate_k8s_secret(package, cert_pem, key_pem, ca_chain_pem, namespace)},
      {"#{package_dir}/kubernetes/configmap.yaml",
       generate_k8s_configmap(package, join_token, namespace, opts)},
      {"#{package_dir}/kubernetes/deployment.yaml",
       generate_k8s_deployment(package, namespace, image_tag)},
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
    component_type = to_string(package.component_type)
    component_id = package.component_id || package.id

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
      name: serviceradar-#{component_type}-tls
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{component_type}
        app.kubernetes.io/component: #{component_type}
        app.kubernetes.io/part-of: serviceradar
        serviceradar.io/component-id: "#{component_id}"
    type: kubernetes.io/tls
    data:
      tls.crt: #{cert_b64}
      tls.key: #{key_b64}
      ca.crt: #{ca_b64}
    """
  end

  defp generate_k8s_configmap(package, join_token, namespace, opts) do
    component_type = to_string(package.component_type)
    component_id = package.component_id || package.id
    core_address = Keyword.get(opts, :core_address, default_core_address())
    nats_url = Keyword.get(opts, :nats_url, default_nats_url())

    config_yaml = """
    component_id: "#{component_id}"
    component_type: "#{component_type}"
    join_token: "#{join_token}"
    core:
      address: "#{core_address}"
    nats:
      url: "#{nats_url}"
    tls:
      cert_file: "/etc/serviceradar/certs/tls.crt"
      key_file: "/etc/serviceradar/certs/tls.key"
      ca_file: "/etc/serviceradar/certs/ca.crt"
    """

    # Add component-specific config
    config_yaml = config_yaml <> component_specific_k8s_config(package)

    config_b64 = Base.encode64(config_yaml)

    """
    # ServiceRadar Edge Component - Configuration
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: serviceradar-#{component_type}-config
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{component_type}
        app.kubernetes.io/component: #{component_type}
        app.kubernetes.io/part-of: serviceradar
    binaryData:
      config.yaml: #{config_b64}
    """
  end

  defp component_specific_k8s_config(package) do
    case package.component_type do
      :poller ->
        """
        poller:
          partition_id: "#{package.site || "default"}"
        """

      :agent ->
        """
        agent:
          poller_id: "#{package.poller_id || ""}"
        """

      :checker ->
        checker_config =
          if package.checker_config_json, do: inspect(package.checker_config_json), else: "{}"

        """
        checker:
          kind: "#{package.checker_kind || ""}"
          config: #{checker_config}
        """

      _ ->
        ""
    end
  end

  defp generate_k8s_deployment(package, namespace, image_tag) do
    component_type = to_string(package.component_type)
    component_id = package.component_id || package.id

    """
    # ServiceRadar Edge Component - Deployment
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: serviceradar-#{component_type}
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{component_type}
        app.kubernetes.io/component: #{component_type}
        app.kubernetes.io/part-of: serviceradar
        serviceradar.io/component-id: "#{component_id}"
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: serviceradar-#{component_type}
      template:
        metadata:
          labels:
            app.kubernetes.io/name: serviceradar-#{component_type}
            app.kubernetes.io/component: #{component_type}
            app.kubernetes.io/part-of: serviceradar
        spec:
          serviceAccountName: serviceradar-#{component_type}
          containers:
            - name: #{component_type}
              image: ghcr.io/carverauto/serviceradar-#{component_type}:#{image_tag}
              args:
                - --config
                - /etc/serviceradar/config/config.yaml
              ports:
                - name: grpc
                  containerPort: 50051
                  protocol: TCP
                - name: metrics
                  containerPort: 9090
                  protocol: TCP
              env:
                - name: SERVICERADAR_COMPONENT_ID
                  value: "#{component_id}"
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
                  port: 50051
                initialDelaySeconds: 10
                periodSeconds: 30
              readinessProbe:
                grpc:
                  port: 50051
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
                secretName: serviceradar-#{component_type}-tls
            - name: config
              configMap:
                name: serviceradar-#{component_type}-config
          securityContext:
            fsGroup: 1000
    ---
    # ServiceAccount for the component
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: serviceradar-#{component_type}
      namespace: #{namespace}
      labels:
        app.kubernetes.io/name: serviceradar-#{component_type}
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
    Application.get_env(:serviceradar_web_ng, :base_url, "https://app.serviceradar.cloud")
  end

  defp default_core_address do
    Application.get_env(:serviceradar_web_ng, :core_address, "core.serviceradar.cloud:50052")
  end

  defp default_nats_url do
    Application.get_env(:serviceradar_web_ng, :nats_url, "nats://nats.serviceradar.cloud:4222")
  end
end
