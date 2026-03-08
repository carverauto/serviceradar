defmodule ServiceRadarWebNG.Edge.CollectorBundleGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CollectorPackage
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
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle?token=download-token"

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
               "https://demo.serviceradar.cloud/api/collectors/12345678-abcd-efgh-ijkl-1234567890ab/bundle?token=download-token"

      assert command =~ "./deploy.sh"
      refute command =~ "sudo ./update.sh"
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
