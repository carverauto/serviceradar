defmodule ServiceRadarWebNG.Edge.CollectorBundleGeneratorTest do
  use ExUnit.Case, async: true

  @moduletag :db_free

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadarWebNG.Edge.CollectorBundleGenerator

  @moduletag :db_free

  describe "create_tarball/4 for falcosidekick" do
    test "does not bundle a second certificate set" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_falcosidekick_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      file_names = Map.keys(files)

      assert Enum.any?(file_names, &String.ends_with?(&1, "/creds/nats.creds"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/falcosidekick.yaml"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/deploy.sh"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/README.md"))

      refute Enum.any?(file_names, &String.contains?(&1, "/certs/"))
    end

    test "projects only the required files from the shared runtime cert secret" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_falcosidekick_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      values_yaml = find_file(files, "falcosidekick.yaml")
      deploy_script = find_file(files, "deploy.sh")
      readme = find_file(files, "README.md")
      values = YamlElixir.read_from_string!(values_yaml)
      cert_volume = Enum.find(values["extraVolumes"], &(&1["name"] == "serviceradar-certs"))

      assert values_yaml =~ "secretName: serviceradar-runtime-certs"

      assert cert_volume["secret"] == %{
               "secretName" => "serviceradar-runtime-certs",
               "items" => [
                 %{"key" => "root.pem", "path" => "root.pem"},
                 %{"key" => "falcosidekick.pem", "path" => "falcosidekick.pem"},
                 %{"key" => "falcosidekick-key.pem", "path" => "falcosidekick-key.pem"}
               ]
             }

      assert values_yaml =~ "cacertfile: /etc/serviceradar/certs/root.pem"
      assert values_yaml =~ "templatedfields:"

      assert values_yaml =~
               ~s(serviceradar.agent_id: '{{ with index . "k8s.node.name" }}agent-{{ . }}{{ end }}')

      assert values_yaml =~
               "OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE: /etc/serviceradar/certs/root.pem"

      refute values_yaml =~ "serviceradar-falcosidekick-certs"
      refute values_yaml =~ "/etc/serviceradar/certs/ca-chain.pem"
      refute values_yaml =~ "root-key.pem"
      refute values_yaml =~ "jwt-secret"
      refute values_yaml =~ "api-key"

      assert deploy_script =~ ~s(SECRET_NAME="serviceradar-runtime-certs")
      assert deploy_script =~ ~s(kubectl get secret "$SECRET_NAME" --namespace "$NAMESPACE")
      refute deploy_script =~ "kubectl create secret generic"
      refute deploy_script =~ "serviceradar-falcosidekick-certs"

      assert readme =~ "serviceradar-runtime-certs"
      refute readme =~ "serviceradar-falcosidekick-certs"
      refute readme =~ "certs/client.pem"
    end
  end

  describe "create_tarball/4 for otel" do
    test "normalizes newline-bearing grpc port overrides before writing TOML" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_otel_package(%{
            "server" => %{"port" => "4317\nmalicious = true"}
          }),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      files = extract_files(tarball)
      otel_toml = find_file(files, "otel.toml")

      assert otel_toml =~ "port = 4317"
      refute otel_toml =~ "malicious = true"
    end
  end

  describe "create_tarball/4 for flowgger" do
    test "omits certificate files when TLS material was not provisioned" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          nil,
          nats_url: "nats://serviceradar-nats:4222"
        )

      file_names = tarball |> extract_files() |> Map.keys()

      assert Enum.any?(file_names, &String.ends_with?(&1, "/creds/nats.creds"))
      assert Enum.any?(file_names, &String.ends_with?(&1, "/config/flowgger.toml"))
      refute Enum.any?(file_names, &String.contains?(&1, "/certs/"))
    end

    test "restarts the collector when the bundle has no certificates" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          nil,
          nats_url: "nats://serviceradar-nats:4222"
        )

      assert {:ok, installed} = install_bundle(tarball)

      assert File.read!(Path.join(installed, "creds/nats.creds")) =~ "BEGIN NATS USER JWT"
      assert File.exists?(Path.join(installed, "flowgger.toml"))
      refute File.exists?(Path.join(installed, "certs/collector.pem"))
      refute File.exists?(Path.join(installed, "certs/collector-key.pem"))
      refute File.exists?(Path.join(installed, "certs/ca-chain.pem"))

      log = File.read!(Path.join(installed, "systemctl.log"))
      assert log =~ "stop serviceradar-flowgger"
      assert log =~ "start serviceradar-flowgger"
    end

    test "installs certificate files when the bundle includes them" do
      package = %{
        sample_flowgger_package()
        | tls_cert_pem: "cert-pem\n",
          ca_chain_pem: "ca-pem\n"
      }

      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          package,
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      assert {:ok, installed} = install_bundle(tarball)

      assert File.read!(Path.join(installed, "certs/collector.pem")) == "cert-pem\n"
      assert File.read!(Path.join(installed, "certs/collector-key.pem")) == sample_tls_key()
      assert File.read!(Path.join(installed, "certs/ca-chain.pem")) == "ca-pem\n"
      assert mode(Path.join(installed, "certs/collector.pem")) == 0o644
      assert mode(Path.join(installed, "certs/ca-chain.pem")) == 0o644
      assert mode(Path.join(installed, "certs/collector-key.pem")) == 0o600
      assert mode(Path.join(installed, "creds/nats.creds")) == 0o600

      log = File.read!(Path.join(installed, "systemctl.log"))
      assert log =~ "stop serviceradar-flowgger"
      assert log =~ "start serviceradar-flowgger"
    end

    test "defaults syslog input to auto detection and UTC" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://host01.example.com:4222"
        )

      flowgger_toml = tarball |> extract_files() |> find_file("flowgger.toml")

      assert flowgger_toml =~ ~s(format = "auto")
      assert flowgger_toml =~ ~s(rfc3164_timezone = "UTC")
    end

    test "preserves explicit RFC3164 and legacy timezone overrides" do
      for {input, timezone} <- [
            {%{"rfc3164_timezone" => "local"}, "local"},
            {%{"timezone" => "America/New_York"}, "America/New_York"},
            {%{"rfc3164_timezone" => "UTC", "timezone" => "America/New_York"}, "UTC"}
          ] do
        {:ok, tarball} =
          CollectorBundleGenerator.create_tarball(
            sample_flowgger_package(%{"input" => input}),
            sample_nats_creds(),
            sample_tls_key(),
            nats_url: "nats://host01.example.com:4222"
          )

        flowgger_toml = tarball |> extract_files() |> find_file("flowgger.toml")

        assert flowgger_toml =~ ~s(rfc3164_timezone = "#{timezone}")
      end
    end
  end

  describe "get_nats_url/2" do
    @tag :db_free
    test "an edge site with no leaf URL writes to the local leaf" do
      package = %CollectorPackage{
        collector_type: :flowgger,
        edge_site: %EdgeSite{nats_leaf_url: nil, nats_leaf_server: %{local_listen: "0.0.0.0:4222"}}
      }

      assert CollectorBundleGenerator.get_nats_url(package) == "tls://127.0.0.1:4222"
    end

    @tag :db_free
    test "an explicit edge site leaf URL overrides the local listen address" do
      package = %CollectorPackage{
        collector_type: :netflow,
        edge_site: %EdgeSite{
          nats_leaf_url: "tls://192.0.2.10:4222",
          nats_leaf_server: %{local_listen: "0.0.0.0:4222"}
        }
      }

      assert CollectorBundleGenerator.get_nats_url(package) == "tls://192.0.2.10:4222"
    end

    @tag :db_free
    test "a collector with no edge site keeps the platform NATS URL" do
      previous = Application.get_env(:serviceradar_web_ng, :nats_url)
      Application.put_env(:serviceradar_web_ng, :nats_url, "tls://nats.example:4222")
      on_exit(fn -> restore_nats_url(previous) end)

      assert CollectorBundleGenerator.get_nats_url(%CollectorPackage{collector_type: :sflow}) ==
               "tls://nats.example:4222"
    end
  end

  describe "update_command/3" do
    test "uses the public collector bundle path for standard collectors" do
      command =
        CollectorBundleGenerator.update_command(
          %CollectorPackage{
            id: "12345678-abcd-efgh-ijkl-1234567890ab",
            collector_type: :flowgger
          },
          "sentinel-token-value",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      # The header name contains "download-token"; the SECRET passed to
      # update_command/3 is the sentinel and must never be embedded verbatim.
      refute command =~ "sentinel-token-value"
      assert command =~ "sudo ./update.sh"
      refute command =~ "/api/edge/collectors/"
    end

    test "uses deploy.sh for falcosidekick bundles" do
      command =
        CollectorBundleGenerator.update_command(
          sample_falcosidekick_package(),
          "sentinel-token-value",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      refute command =~ "sentinel-token-value"
      assert command =~ "./deploy.sh"
      refute command =~ "sudo ./update.sh"
    end

    test "quotes bundle URLs as shell literals" do
      command =
        CollectorBundleGenerator.update_command(
          %CollectorPackage{
            id: "12345678-abcd-efgh-ijkl-1234567890ab",
            collector_type: :flowgger
          },
          "download-token",
          base_url: "https://demo.serviceradar.cloud/$(touch /tmp/pwned)"
        )

      assert command =~
               "'https://demo.serviceradar.cloud/$(touch /tmp/pwned)/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle'"

      refute command =~
               "\"https://demo.serviceradar.cloud/$(touch /tmp/pwned)/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle\""
    end
  end

  defp install_bundle(tarball) do
    root = Path.join(System.tmp_dir!(), "collector-update-#{System.unique_integer([:positive])}")
    bundle = Path.join(root, "bundle")
    config = Path.join(root, "etc")
    bin = Path.join(root, "bin")
    log = Path.join(config, "systemctl.log")

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(bundle)
    File.mkdir_p!(bin)
    File.mkdir_p!(config)
    File.write!(log, "")

    Enum.each(extract_files(tarball), fn {name, content} ->
      relative = name |> String.split("/", parts: 2) |> List.last()
      dest = Path.join(bundle, relative)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end)

    script_path = Path.join(bundle, "update.sh")

    script =
      script_path
      |> File.read!()
      |> String.replace(~s([ "$EUID" -ne 0 ]), ~s([ "${SR_TEST_EUID:-$EUID}" -ne 0 ]))
      |> String.replace(~s(CONFIG_DIR="/etc/serviceradar"), ~s(CONFIG_DIR="#{config}"))

    File.write!(script_path, script)
    File.write!(Path.join(bin, "systemctl"), stub_systemctl(log))
    File.write!(Path.join(bin, "id"), "#!/bin/bash\nexit 1\n")
    File.chmod!(Path.join(bin, "systemctl"), 0o755)
    File.chmod!(Path.join(bin, "id"), 0o755)

    env =
      System.get_env()
      |> Map.put("PATH", bin <> ":" <> System.get_env("PATH", ""))
      |> Map.put("SR_TEST_EUID", "0")
      |> Map.to_list()

    {output, status} = System.cmd("bash", [script_path], env: env, stderr_to_stdout: true)

    if status == 0 do
      {:ok, config}
    else
      {:error, {status, output}}
    end
  end

  defp stub_systemctl(log) do
    """
    #!/bin/bash
    printf '%s\\n' "$*" >> "#{log}"
    if [ "$1" = "list-unit-files" ]; then
      echo "serviceradar-flowgger.service enabled"
    fi
    exit 0
    """
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  defp extract_files(tarball) do
    {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    Map.new(files, fn {name, content} ->
      {to_string(name), IO.iodata_to_binary(content)}
    end)
  end

  defp find_file(files, suffix) do
    Enum.find_value(files, fn {name, content} ->
      if String.ends_with?(name, suffix), do: content
    end)
  end

  defp sample_falcosidekick_package do
    %CollectorPackage{
      id: "12345678-abcd-efgh-ijkl-1234567890ab",
      collector_type: :falcosidekick,
      site: "demo",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      config_overrides: %{
        "namespace" => "demo",
        "release_name" => "falcosidekick-nats-auth"
      }
    }
  end

  defp sample_otel_package(config_overrides \\ %{}) do
    %CollectorPackage{
      id: "87654321-dcba-hgfe-lkji-0987654321ba",
      collector_type: :otel,
      site: "demo",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      config_overrides: config_overrides
    }
  end

  defp sample_flowgger_package(config_overrides \\ %{}) do
    %CollectorPackage{
      id: "abcdef12-3456-7890-abcd-ef1234567890",
      collector_type: :flowgger,
      site: "SITE01",
      inserted_at: ~U[2030-10-06 03:20:29Z],
      config_overrides: config_overrides
    }
  end

  defp restore_nats_url(nil), do: Application.delete_env(:serviceradar_web_ng, :nats_url)
  defp restore_nats_url(value), do: Application.put_env(:serviceradar_web_ng, :nats_url, value)

  defp sample_nats_creds do
    """
    -----BEGIN NATS USER JWT-----
    dGVzdC11c2VyLWp3dA==
    ------END NATS USER JWT------
    """
  end

  defp sample_tls_key do
    """
    -----BEGIN PRIVATE KEY-----
    dGVzdC10bHMta2V5
    -----END PRIVATE KEY-----
    """
  end
end
