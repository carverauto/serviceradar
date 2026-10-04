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
        "assignment_id" => "assign-01",
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
    assert PluginIngestor.supports?(payload(nil))
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

  test "cleans every owned reference after an earlier batch download fails" do
    second_key = "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/1002"
    {:ok, first} = PluginIngestor.extract(payload())
    batch = %{"labels" => %{"kind" => "running_config", "assignment_id" => "assign-01"}, "details" => %{
      "running_configs" => [
        %{"device_uid" => first.device_uid, "artifact" => %{"object_key" => @object_key, "sha256" => @sha256}},
        %{"artifact" => %{"object_key" => second_key}}
      ]
    }}

    assert {:error, {:running_config_artifact_fetch_failed, :unavailable}} =
      PluginIngestor.ingest(batch, @status,
        artifact_fetcher: fn @object_key -> {:error, :unavailable} end,
        artifact_deleter: fn key -> send(self(), {:deleted, key}); :ok end
      )
    assert_received {:deleted, @object_key}
    assert_received {:deleted, ^second_key}
  end

  test "cleans malformed results, hash failures and fetch exceptions" do
    malformed = put_in(payload(), ["labels", "device_uid"], nil)
    malformed = Map.put(malformed, "details", %{"artifact" => %{"object_key" => @object_key}})
    cases = [
      {malformed, fn _ -> flunk("malformed result must not fetch") end, :missing_running_config},
      {payload(), fn _ -> {:ok, "tampered"} end, :running_config_artifact_hash_mismatch},
      {payload(), fn _ -> raise "download unavailable" end, :running_config_ingest_failed}
    ]

    for {input, fetch, error} <- cases do
      assert {:error, ^error} = PluginIngestor.ingest(input, @status,
        artifact_fetcher: fetch,
        artifact_deleter: fn key -> send(self(), {:deleted, key}); :ok end)
      assert_received {:deleted, @object_key}
    end
  end

  test "an incomplete staging result deletes references without ingesting them" do
    {:ok, ref} = PluginIngestor.extract(payload())
    batch = %{"labels" => %{"kind" => "running_config", "assignment_id" => "assign-01"}, "details" => %{
      "complete" => false,
      "running_configs" => [%{"device_uid" => ref.device_uid, "artifact" => %{"object_key" => @object_key, "sha256" => @sha256}}]
    }}
    assert {:error, :running_config_result_incomplete} = PluginIngestor.ingest(batch, @status,
      artifact_fetcher: fn _ -> flunk("must not ingest partial staging") end,
      artifact_deleter: fn key -> send(self(), {:deleted, key}); :ok end)
    assert_received {:deleted, @object_key}
  end

  test "cleans pre-upgrade legacy device keys staged before canonicalization" do
    for device <- ["01001", "abc"] do
      key = "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/#{device}"
      assert :ok = PluginIngestor.discard_artifacts(
        payload(%{"object_key" => key, "sha256" => @sha256}), @status,
        artifact_deleter: fn ^key -> send(self(), {:deleted, key}); :ok end)
      assert_received {:deleted, ^key}
    end
  end

  test "cleanup cannot delete another agent's or another provider's artifact" do
    for key <- [
      "agent-artifacts/agent-02/assign-01/opentext-nom/running-config/1001",
      "agent-artifacts/agent-01/assign-02/opentext-nom/running-config/1001",
      "agent-artifacts/agent-01/assign-01/other-plugin/report/1001",
      "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/../1001",
      "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/01001/" <> String.duplicate("a", 32),
      "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/1001/" <> String.duplicate("A", 32)
    ] do
      assert {:error, :running_config_artifact_cleanup_failed} = PluginIngestor.ingest(
        payload(%{"object_key" => key, "sha256" => @sha256}), @status,
        artifact_fetcher: fn _ -> flunk("must not fetch unowned config") end,
        artifact_deleter: fn _ -> flunk("must not delete unowned config") end)
    end
  end

  test "cleanup continues after delete failure and reports failure" do
    second_key = "agent-artifacts/agent-01/assign-01/opentext-nom/running-config/1002"
    assert {:error, :running_config_artifact_cleanup_failed} = PluginIngestor.discard_artifacts(
      [payload(), payload(%{"object_key" => second_key})], @status,
      artifact_deleter: fn
        @object_key -> {:error, :unavailable}
        key -> send(self(), {:deleted, key}); :ok
      end)
    assert_received {:deleted, ^second_key}
  end
  test "a delayed result deletes only its attempt and requires host-attested assignment identity" do
    old_key = @object_key <> "/" <> String.duplicate("a", 32)
    newer_key = @object_key <> "/" <> String.duplicate("b", 32)
    input = payload(%{"object_key" => old_key, "sha256" => @sha256})
    assert :ok = PluginIngestor.discard_artifacts(input, @status,
      artifact_deleter: fn key ->
        assert key == old_key
        refute key == newer_key
        :ok
      end)

    unattested = update_in(input, ["labels"], &Map.delete(&1, "assignment_id"))
    {:ok, ref} = PluginIngestor.extract(unattested)
    assert {:error, :running_config_artifact_assignment_not_owned} =
      PluginIngestor.fetch_body(ref, @status,
        artifact_fetcher: fn _ -> flunk("must not fetch without attested assignment") end)
    assert {:error, :running_config_artifact_cleanup_failed} =
      PluginIngestor.discard_artifacts(unattested, @status,
        artifact_deleter: fn _ -> flunk("must not delete without attested assignment") end)
  end

end
