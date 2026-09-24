defmodule ServiceRadar.NetworkConfig.PluginIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.PluginIngestor

  @body "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n"
  @sha256 :sha256 |> :crypto.hash(@body) |> Base.encode16(case: :lower)
  @object_key "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/1001"
  @status %{agent_id: "agent-01"}

  defp payload(artifact \\ %{"object_key" => @object_key, "sha256" => @sha256}) do
    %{
      "status" => "OK",
      "labels" => %{
        "source" => "opentext-nom",
        "kind" => "running_config",
        "device_uid" => "sr:host01.example.com"
      },
      "details" =>
        Jason.encode!(%{
          "kind" => "running_config",
          "config_kind" => "running",
          "device_uid" => "sr:host01.example.com",
          "content_hash" => @sha256,
          "artifact" => artifact
        })
    }
  end

  defp fetcher(result), do: [artifact_fetcher: fn @object_key -> result end]

  test "supports running-config results that reference a staged artifact" do
    assert PluginIngestor.supports?(payload())
    refute PluginIngestor.supports?(payload(nil))
    refute PluginIngestor.supports?(%{"labels" => %{"source" => "opentext-nom"}})
  end

  test "does not claim unrelated plugin results" do
    advisory = %{
      "status" => "OK",
      "labels" => %{"source" => "advisory-feed"},
      "details" => Jason.encode!(%{"advisories" => []})
    }

    refute PluginIngestor.supports?(advisory, @status)
  end

  test "extracts the artifact reference and never a body" do
    assert {:ok, ref} = PluginIngestor.extract(payload())
    assert ref.device_uid == "sr:host01.example.com"
    assert ref.object_key == @object_key
    assert ref.sha256 == @sha256
    assert ref.config_kind == :running
    refute Map.has_key?(ref, :body)
    refute Map.has_key?(ref, :facts)
  end

  test "fetches the body from the artifact and verifies its hash" do
    {:ok, ref} = PluginIngestor.extract(payload())

    assert {:ok, @body} = PluginIngestor.fetch_body(ref, @status, fetcher({:ok, {nil, @body}}))
    assert {:ok, @body} = PluginIngestor.fetch_body(ref, @status, fetcher({:ok, @body}))
  end

  test "rejects an artifact whose bytes do not match the recorded hash" do
    {:ok, ref} = PluginIngestor.extract(payload())

    assert {:error, :running_config_artifact_hash_mismatch} =
             PluginIngestor.fetch_body(ref, @status, fetcher({:ok, "tampered\n"}))
  end

  test "surfaces a failed artifact download" do
    {:ok, ref} = PluginIngestor.extract(payload())

    assert {:error, {:running_config_artifact_fetch_failed, :unavailable}} =
             PluginIngestor.fetch_body(ref, @status, fetcher({:error, :unavailable}))
  end

  test "refuses an object key outside the reporting agent's artifact prefix" do
    {:ok, ref} = PluginIngestor.extract(payload())
    never = [artifact_fetcher: fn _key -> flunk("must not fetch another agent's object") end]

    assert {:error, :running_config_artifact_key_not_owned} =
             PluginIngestor.fetch_body(ref, %{agent_id: "agent-02"}, never)

    assert {:error, :running_config_artifact_agent_unknown} =
             PluginIngestor.fetch_body(ref, %{}, never)

    traversal = %{ref | object_key: "agent-artifacts/agent-01/../agent-02/secret"}

    assert {:error, :running_config_artifact_key_invalid} =
             PluginIngestor.fetch_body(traversal, @status, never)
  end
end
