defmodule ServiceRadarWebNG.FieldSurveyArtifactStoreTest do
  use ExUnit.Case, async: true

  alias Gnat.Jetstream.API.Object
  alias ServiceRadarWebNG.FieldSurveyArtifactStore

  @moduletag :jetstream_retirement

  test "loads the integrated Gnat JetStream object-store API" do
    assert Code.ensure_loaded?(Object)
    assert Code.ensure_loaded?(Gnat.Jetstream.API.Stream)
    assert function_exported?(Object, :put, 4)
    assert function_exported?(Object, :get, 4)
    assert function_exported?(Gnat.Jetstream.API.Stream, :info, 2)
  end

  test "validates keys and blobs before object-store access" do
    assert {:error, :invalid_blob} = FieldSurveyArtifactStore.put_blob(nil, "payload")
    assert {:error, :invalid_blob} = FieldSurveyArtifactStore.put_blob("scan.arrow", nil)
    assert {:error, :invalid_key} = FieldSurveyArtifactStore.fetch_blob(nil)
  end

  test "hashes artifact payloads deterministically" do
    assert FieldSurveyArtifactStore.sha256("payload") ==
             "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5"
  end
end
