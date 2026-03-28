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
          "url" => "http://example.test/releases/agent.tar.gz"
        }
      ]
    }

    assert {:error, errors} = ReleaseManifestValidator.validate("1.2.3", manifest, sign_manifest(manifest))

    messages = Enum.map(errors, & &1.message)
    assert "release artifact 1 must include sha256" in messages
    assert "release artifact 1 url must use https" in messages
  end

  defp valid_manifest(version) do
    %{
      "version" => version,
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "url" => "https://example.test/releases/#{version}/serviceradar-agent.tar.gz",
          "sha256" => String.duplicate("a", 64),
          "format" => "tar.gz",
          "entrypoint" => "serviceradar-agent"
        }
      ]
    }
  end

  defp sign_manifest(manifest) do
    {:ok, payload} = ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
