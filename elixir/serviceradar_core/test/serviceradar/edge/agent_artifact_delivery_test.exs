defmodule ServiceRadar.Edge.AgentArtifactDeliveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AgentArtifactDelivery
  alias ServiceRadar.Edge.AgentArtifacts

  setup do
    start_agent_artifacts()
    :ok = AgentArtifacts.clear()

    original_storage = Application.get_env(:serviceradar_core, :plugin_storage)

    Application.put_env(:serviceradar_core, :plugin_storage,
      public_url: "https://gateway.example",
      signing_secret: "test-secret"
    )

    on_exit(fn ->
      _ = AgentArtifacts.clear()
      restore_plugin_storage(original_storage)
    end)

    :ok
  end

  test "resolves published token artifact and attaches caller agent" do
    assert {:ok, publication} =
             AgentArtifacts.publish_catalog(%{
               source_id: "source-1",
               object_key: "objects/test.json",
               file_name: "test.json"
             })

    assert publication.token_id == "catalog-source:source-1:active"

    assert {:ok, download} =
             AgentArtifactDelivery.resolve_token_artifact_download(
               publication.token_id,
               "objects/test.json",
               "agent-123"
             )

    assert download.object_key == "objects/test.json"
    assert download.file_name == "test.json"
    assert download.content_type == "application/json"
    assert download.agent_id == "agent-123"
  end

  test "rejects unpublished token artifact" do
    assert {:error, :unauthorized} =
             AgentArtifactDelivery.resolve_token_artifact_download(
               "unknown-source",
               "objects/test.json",
               "agent-123"
             )
  end

  test "rejects object keys not published for the token" do
    assert {:ok, _publication} =
             AgentArtifacts.publish(%{
               token_id: "test-source",
               object_key: "objects/test.json"
             })

    assert {:error, :unauthorized} =
             AgentArtifactDelivery.resolve_token_artifact_download(
               "test-source",
               "objects/other.json",
               "agent-123"
             )
  end

  test "publishes catalog assignment with download request" do
    assert {:ok, assignment} =
             AgentArtifacts.publish_catalog_assignment(%{
               source_id: "catalog-source-1",
               snapshot_ref: "snapshot-1",
               catalog_version: "v1",
               source_revision: "rev-1",
               object_key: "objects/catalog.json",
               sha256: "abc123",
               size_bytes: 42
             })

    assert assignment["schema_version"] == "serviceradar.catalog_assignment.v1"
    assert assignment["snapshot_ref"] == "snapshot-1"
    assert assignment["catalog_version"] == "v1"
    assert assignment["source_revision"] == "rev-1"
    assert assignment["object_key"] == "objects/catalog.json"
    assert assignment["sha256"] == "abc123"
    assert assignment["size_bytes"] == 42
    assert is_binary(assignment["download_url"])
    assert is_binary(assignment["download_token"])
  end

  defp start_agent_artifacts do
    case Process.whereis(AgentArtifacts) do
      pid when is_pid(pid) -> :ok
      nil -> start_supervised!(AgentArtifacts)
    end
  end

  defp restore_plugin_storage(nil),
    do: Application.delete_env(:serviceradar_core, :plugin_storage)

  defp restore_plugin_storage(original),
    do: Application.put_env(:serviceradar_core, :plugin_storage, original)
end
