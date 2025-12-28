defmodule ServiceRadarWebNG.Edge.BundleGeneratorTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Edge.BundleGenerator
  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadar.Identity.Tenant

  # Create a tenant for all tests
  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Bundle Test Org",
          slug: "bundle-test-org-#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )
      |> Ash.create()

    # Create a test package
    {:ok, result} =
      OnboardingPackages.create(
        %{label: "test-bundle-pkg", component_type: :poller, component_id: "poller-test-bundle"},
        tenant: tenant.id
      )

    %{
      tenant: tenant,
      tenant_id: tenant.id,
      package: result.package,
      join_token: result.join_token,
      download_token: result.download_token
    }
  end

  describe "create_tarball/4" do
    test "creates a valid gzipped tarball", %{package: package, join_token: join_token} do
      bundle_pem = sample_bundle_pem()

      assert {:ok, tarball} = BundleGenerator.create_tarball(package, bundle_pem, join_token)

      # Verify it's valid gzip data
      assert is_binary(tarball)
      assert byte_size(tarball) > 0

      # Decompress and verify contents
      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      file_names = Enum.map(files, fn {name, _content} -> to_string(name) end)

      # Verify expected files are present
      assert Enum.any?(file_names, &String.contains?(&1, "component.pem"))
      assert Enum.any?(file_names, &String.contains?(&1, "component-key.pem"))
      assert Enum.any?(file_names, &String.contains?(&1, "ca-chain.pem"))
      assert Enum.any?(file_names, &String.contains?(&1, "config.yaml"))
      assert Enum.any?(file_names, &String.contains?(&1, "install.sh"))
      assert Enum.any?(file_names, &String.contains?(&1, "README.md"))
    end

    test "generates install.sh with correct component type", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, "", join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      {_, install_sh} = Enum.find(files, fn {name, _} ->
        to_string(name) |> String.ends_with?("install.sh")
      end)

      assert install_sh =~ "COMPONENT_TYPE=\"poller\""
      assert install_sh =~ "Platform-detecting installer"
      assert install_sh =~ "docker"
      assert install_sh =~ "systemd"
    end

    test "generates config.yaml with correct structure", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, "", join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      {_, config_yaml} = Enum.find(files, fn {name, _} ->
        to_string(name) |> String.ends_with?("config.yaml")
      end)

      assert config_yaml =~ "component_type:"
      assert config_yaml =~ "join_token:"
      assert config_yaml =~ "tls:"
      assert config_yaml =~ "component.pem"
    end

    test "handles empty bundle_pem gracefully", %{package: package, join_token: join_token} do
      assert {:ok, tarball} = BundleGenerator.create_tarball(package, "", join_token)
      assert is_binary(tarball)
    end
  end

  describe "bundle_filename/1" do
    test "generates correct filename format", %{package: package} do
      filename = BundleGenerator.bundle_filename(package)

      assert filename =~ "edge-package-"
      assert filename =~ ".tar.gz"
      # Should contain first 8 chars of package ID
      assert String.length(filename) > 20
    end
  end

  describe "docker_install_command/3" do
    test "generates valid docker install command", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.docker_install_command(package, download_token)

      assert cmd =~ "curl -fsSL"
      assert cmd =~ package.id
      assert cmd =~ download_token
      assert cmd =~ "docker run"
      assert cmd =~ "serviceradar-poller"
    end

    test "uses custom base_url option", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.docker_install_command(package, download_token,
        base_url: "https://custom.example.com"
      )

      assert cmd =~ "https://custom.example.com"
    end

    test "uses custom image_tag option", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.docker_install_command(package, download_token,
        image_tag: "v1.2.3"
      )

      assert cmd =~ ":v1.2.3"
    end
  end

  describe "systemd_install_command/3" do
    test "generates valid systemd install command", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.systemd_install_command(package, download_token)

      assert cmd =~ "curl -fsSL"
      assert cmd =~ package.id
      assert cmd =~ download_token
      assert cmd =~ "sudo ./install.sh"
    end

    test "uses custom base_url option", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.systemd_install_command(package, download_token,
        base_url: "https://my-server.local"
      )

      assert cmd =~ "https://my-server.local"
    end
  end

  describe "kubernetes_install_command/3" do
    test "generates valid kubernetes install command", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.kubernetes_install_command(package, download_token)

      assert cmd =~ "curl -fsSL"
      assert cmd =~ package.id
      assert cmd =~ download_token
      assert cmd =~ "kubectl apply -f kubernetes/"
      assert cmd =~ "-n serviceradar"
    end

    test "uses custom namespace option", %{package: package, download_token: download_token} do
      cmd = BundleGenerator.kubernetes_install_command(package, download_token,
        namespace: "my-namespace"
      )

      assert cmd =~ "-n my-namespace"
    end
  end

  describe "kubernetes manifests in bundle" do
    test "bundle contains kubernetes manifests", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, sample_bundle_pem(), join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])
      file_names = Enum.map(files, fn {name, _} -> to_string(name) end)

      # Verify kubernetes manifest files are present
      assert Enum.any?(file_names, &String.ends_with?(&1, "kubernetes/namespace.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "kubernetes/secret.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "kubernetes/configmap.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "kubernetes/deployment.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "kubernetes/kustomization.yaml"))
    end

    test "kubernetes secret contains base64-encoded certificates", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, sample_bundle_pem(), join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      {_, secret_yaml} = Enum.find(files, fn {name, _} ->
        to_string(name) |> String.ends_with?("kubernetes/secret.yaml")
      end)

      # Verify secret structure
      assert secret_yaml =~ "kind: Secret"
      assert secret_yaml =~ "type: kubernetes.io/tls"
      assert secret_yaml =~ "tls.crt:"
      assert secret_yaml =~ "tls.key:"
      assert secret_yaml =~ "ca.crt:"
    end

    test "kubernetes deployment has correct security context", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, sample_bundle_pem(), join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      {_, deployment_yaml} = Enum.find(files, fn {name, _} ->
        to_string(name) |> String.ends_with?("kubernetes/deployment.yaml")
      end)

      # Verify deployment has security best practices
      assert deployment_yaml =~ "kind: Deployment"
      assert deployment_yaml =~ "runAsNonRoot: true"
      assert deployment_yaml =~ "readOnlyRootFilesystem: true"
      assert deployment_yaml =~ "allowPrivilegeEscalation: false"
      assert deployment_yaml =~ "ServiceAccount"
    end

    test "kustomization file references all manifests", %{package: package, join_token: join_token} do
      {:ok, tarball} = BundleGenerator.create_tarball(package, sample_bundle_pem(), join_token)

      {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

      {_, kustomization} = Enum.find(files, fn {name, _} ->
        to_string(name) |> String.ends_with?("kubernetes/kustomization.yaml")
      end)

      assert kustomization =~ "kind: Kustomization"
      assert kustomization =~ "namespace.yaml"
      assert kustomization =~ "secret.yaml"
      assert kustomization =~ "configmap.yaml"
      assert kustomization =~ "deployment.yaml"
    end
  end

  # Helper function to generate sample PEM data
  defp sample_bundle_pem do
    """
    # Component Certificate
    -----BEGIN CERTIFICATE-----
    MIIBkjCB/AIJAKHBfpeg1kP1MA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl
    c3RjYTAeFw0yMzAxMDEwMDAwMDBaFw0yNDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMM
    CXRlc3QtY29tcDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABAAAAAAAAAAAAAAAAA==
    -----END CERTIFICATE-----
    # Component Private Key
    -----BEGIN RSA PRIVATE KEY-----
    MIIBogIBAAJBAKHBfpeg1kP1MA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl
    c3RjYTAeFw0yMzAxMDEwMDAwMDBaFw0yNDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMM
    -----END RSA PRIVATE KEY-----
    # CA Chain
    -----BEGIN CERTIFICATE-----
    MIIBkjCB/AIJAKHBfpeg1kP1MA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBnRl
    c3RjYTAeFw0yMzAxMDEwMDAwMDBaFw0yNDAxMDEwMDAwMDBaMBQxEjAQBgNVBAMM
    -----END CERTIFICATE-----
    """
  end
end
