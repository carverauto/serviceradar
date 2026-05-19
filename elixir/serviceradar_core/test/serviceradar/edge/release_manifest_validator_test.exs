defmodule ServiceRadar.Edge.ReleaseManifestValidatorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ReleaseManifestValidator

  @release_public_key "ot8W1BsqSvXV7KEjLL+RkQz106lzcIJNCY91OXSqBpk="
  @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

  setup_all do
    previous = Application.get_env(:serviceradar_core, :agent_release_public_key)
    Application.put_env(:serviceradar_core, :agent_release_public_key, @release_public_key)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :agent_release_public_key)
      else
        Application.put_env(:serviceradar_core, :agent_release_public_key, previous)
      end
    end)

    :ok
  end

  test "accepts a valid signed release manifest" do
    manifest = valid_manifest("1.2.3")
    signature = sign_manifest(manifest)

    assert :ok = ReleaseManifestValidator.validate("1.2.3", manifest, signature)
  end

  test "accepts valid RDP artifact helper metadata" do
    manifest =
      "1.2.3"
      |> valid_manifest()
      |> put_in(["artifacts", Access.at(0)], valid_rdp_artifact("1.2.3"))

    assert :ok = ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))
  end

  test "rejects an invalid signature" do
    manifest = valid_manifest("1.2.3")

    assert {:error, errors} =
             ReleaseManifestValidator.validate(
               "1.2.3",
               manifest,
               Base.encode64("invalid-signature")
             )

    assert Enum.any?(errors, &(&1.field == :signature))
  end

  test "rejects incomplete or insecure artifact metadata" do
    manifest = %{
      "version" => "1.2.3",
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "url" => "http://example.com/releases/agent.tar.gz"
        }
      ]
    }

    assert {:error, errors} =
             ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

    messages = Enum.map(errors, & &1.message)
    assert "release artifact 1 must include sha256" in messages
    assert "release artifact 1 url must use a trusted public https host" in messages
  end

  test "rejects malformed optional artifact metadata" do
    manifest =
      "1.2.3"
      |> valid_manifest()
      |> put_in(["artifacts", Access.at(0), "capabilities"], "remote_access.rdp")
      |> put_in(["artifacts", Access.at(0), "helper_protocol_version"], "")
      |> put_in(["artifacts", Access.at(0), "deployment_requirements"], ["helper"])
      |> put_in(["artifacts", Access.at(0), "sbom"], ["sbom.spdx.json"])

    assert {:error, errors} =
             ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

    messages = Enum.map(errors, & &1.message)
    assert "release artifact 1 capabilities must be a list" in messages
    assert "release artifact 1 helper_protocol_version must be a non-empty string" in messages
    assert "release artifact 1 deployment_requirements must be an object" in messages
    assert "release artifact 1 sbom must contain objects" in messages
  end

  test "rejects RDP artifacts without helper readiness metadata" do
    manifest =
      "1.2.3"
      |> valid_manifest()
      |> put_in(["artifacts", Access.at(0), "capabilities"], ["agent", "remote_access.rdp"])
      |> update_in(["artifacts", Access.at(0)], &Map.delete(&1, "helper_protocol_version"))
      |> update_in(["artifacts", Access.at(0)], &Map.delete(&1, "compatible_agent_versions"))
      |> put_in(["artifacts", Access.at(0), "deployment_requirements"], %{
        "helper" => "",
        "helper_connector_ready" => false,
        "requires_helper_readiness_probe" => false
      })

    assert {:error, errors} =
             ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

    messages = Enum.map(errors, & &1.message)
    assert "release artifact 1 RDP capability requires helper_protocol_version" in messages

    assert "release artifact 1 RDP capability requires compatible_agent_versions.min and max" in messages

    assert "release artifact 1 RDP deployment_requirements requires helper" in messages
    assert "release artifact 1 RDP deployment_requirements requires install_path" in messages

    assert "release artifact 1 RDP deployment_requirements requires helper_capabilities_arg" in messages

    assert "release artifact 1 RDP deployment_requirements.requires_helper_readiness_probe must be true" in messages

    assert "release artifact 1 RDP deployment_requirements.release_phase must be experimental while helper_connector_ready is false" in messages

    assert "release artifact 1 RDP deployment_requirements.helper_connector_ready_reason is required while helper_connector_ready is false" in messages
  end

  test "rejects RDP artifacts with stale helper readiness reason when connector is ready" do
    manifest =
      "1.2.3"
      |> valid_manifest()
      |> put_in(["artifacts", Access.at(0)], valid_rdp_artifact("1.2.3"))
      |> put_in(
        ["artifacts", Access.at(0), "deployment_requirements", "helper_connector_ready"],
        true
      )

    assert {:error, errors} =
             ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

    messages = Enum.map(errors, & &1.message)

    assert "release artifact 1 RDP deployment_requirements.helper_connector_ready_reason must be absent while helper_connector_ready is true" in messages
  end

  test "rejects non-printable or oversized RDP helper readiness reasons" do
    for reason <- ["connector\nnot\tready", String.duplicate("x", 257)] do
      manifest =
        "1.2.3"
        |> valid_manifest()
        |> put_in(["artifacts", Access.at(0)], valid_rdp_artifact("1.2.3"))
        |> put_in(
          ["artifacts", Access.at(0), "deployment_requirements", "helper_connector_ready_reason"],
          reason
        )

      assert {:error, errors} =
               ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

      messages = Enum.map(errors, & &1.message)

      assert "release artifact 1 RDP deployment_requirements.helper_connector_ready_reason must be printable and at most 256 bytes" in messages
    end
  end

  defp valid_manifest(version) do
    %{
      "version" => version,
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "url" => "https://example.com/releases/#{version}/serviceradar-agent.tar.gz",
          "sha256" => String.duplicate("a", 64),
          "format" => "tar.gz",
          "entrypoint" => "serviceradar-agent",
          "capabilities" => ["agent"],
          "checksums" => %{"sha256" => String.duplicate("a", 64)},
          "deployment_requirements" => %{}
        }
      ]
    }
  end

  defp valid_rdp_artifact(version) do
    %{
      "os" => "linux",
      "arch" => "amd64",
      "url" => "https://example.com/releases/#{version}/serviceradar-agent-rdp.tar.gz",
      "sha256" => String.duplicate("b", 64),
      "format" => "tar.gz",
      "entrypoint" => "serviceradar-agent",
      "capabilities" => ["agent", "remote_access.rdp"],
      "helper_protocol_version" => "srdp-helper-v1",
      "compatible_agent_versions" => %{"min" => version, "max" => version},
      "checksums" => %{"sha256" => String.duplicate("b", 64)},
      "deployment_requirements" => %{
        "helper" => "serviceradar-rdp-adapter",
        "install_path" => "/usr/local/bin/serviceradar-rdp-adapter",
        "helper_capabilities_arg" => "--capabilities",
        "helper_connector_ready" => false,
        "helper_connector_ready_reason" => "connector_loop_not_implemented",
        "requires_helper_readiness_probe" => true,
        "release_phase" => "experimental"
      }
    }
  end

  defp sign_manifest(manifest) do
    {:ok, payload} = ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :eddsa
    |> :crypto.sign(:none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
