defmodule ServiceRadarWebNG.Edge.CollectorBundleGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadarWebNG.Edge.CollectorBundleGenerator

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

    test "uses the shared runtime cert secret in generated values and deploy script" do
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

      assert values_yaml =~ "secretName: serviceradar-runtime-certs"
      assert values_yaml =~ "cacertfile: /etc/serviceradar/certs/root.pem"
      assert values_yaml =~ "templatedfields:"

      assert values_yaml =~
               ~s(serviceradar.agent_id: '{{ with index . "k8s.node.name" }}agent-{{ . }}{{ end }}')

      assert values_yaml =~
               "OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE: /etc/serviceradar/certs/root.pem"

      refute values_yaml =~ "serviceradar-falcosidekick-certs"
      refute values_yaml =~ "/etc/serviceradar/certs/ca-chain.pem"

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
    test "defaults syslog input to auto detection and keeps timezone configuration" do
      {:ok, tarball} =
        CollectorBundleGenerator.create_tarball(
          sample_flowgger_package(),
          sample_nats_creds(),
          sample_tls_key(),
          nats_url: "nats://serviceradar-nats:4222"
        )

      flowgger_toml = tarball |> extract_files() |> find_file("flowgger.toml")

      assert flowgger_toml =~ ~s(format = "auto")
      assert flowgger_toml =~ ~s(rfc3164_timezone = "local")
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
          "download-token",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      refute command =~ "download-token"
      assert command =~ "sudo ./update.sh"
      refute command =~ "/api/edge/collectors/"
    end

    test "uses deploy.sh for falcosidekick bundles" do
      command =
        CollectorBundleGenerator.update_command(
          sample_falcosidekick_package(),
          "download-token",
          base_url: "https://demo.serviceradar.cloud"
        )

      assert command =~
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle"

      assert command =~ "-X POST"
      assert command =~ "x-serviceradar-download-token: ${SR_TOKEN}"
      refute command =~ "download-token"
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

  defp sample_flowgger_package do
    %CollectorPackage{
      id: "abcdef12-3456-7890-abcd-ef1234567890",
      collector_type: :flowgger,
      site: "demo",
      inserted_at: ~U[2026-03-08 12:00:00Z],
      config_overrides: %{}
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
