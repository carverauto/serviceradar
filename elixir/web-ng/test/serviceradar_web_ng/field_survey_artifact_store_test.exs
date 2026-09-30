defmodule ServiceRadarWebNG.FieldSurveyArtifactStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gnat.Jetstream.API.Object
  alias ServiceRadarWebNG.FieldSurveyArtifactStore

  @moduletag :db_free

  @moduletag :jetstream_retirement

  @gib 1_073_741_824

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

  describe "reconcile_bucket/1" do
    # Database-free: runs in the Bazel `:db_free` unit tier.
    @describetag :db_free

    setup do
      original = Application.get_env(:serviceradar_web_ng, :field_survey_artifact_store)
      bucket = "fieldsurvey_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:serviceradar_web_ng, :field_survey_artifact_store)
        else
          Application.put_env(:serviceradar_web_ng, :field_survey_artifact_store, original)
        end
      end)

      {:ok, bucket: bucket, stream: "OBJ_#{bucket}"}
    end

    test "creates an absent bucket with the 1 GiB default cap", %{bucket: bucket, stream: stream} do
      put_store_config(jetstream_bucket: bucket)

      assert {:ok, :create} = FieldSurveyArtifactStore.reconcile_bucket(fake_jetstream(:absent))

      create_subject = "$JS.API.STREAM.CREATE.#{stream}"
      assert_received {:js, ^create_subject, payload}
      assert Jason.decode!(payload)["max_bytes"] == @gib
    end

    test "caps an existing unlimited bucket whose data fits instead of leaving it unlimited",
         %{bucket: bucket, stream: stream} do
      put_store_config(jetstream_bucket: bucket)

      assert {:ok, {:update, max_bytes}} =
               FieldSurveyArtifactStore.reconcile_bucket(fake_jetstream({-1, div(@gib, 10)}))

      assert max_bytes == @gib
      update_subject = "$JS.API.STREAM.UPDATE.#{stream}"
      assert_received {:js, ^update_subject, payload}
      assert Jason.decode!(payload)["max_bytes"] == @gib
    end

    test "leaves an unlimited bucket holding more than the cap unlimited and logs it",
         %{bucket: bucket} do
      put_store_config(jetstream_bucket: bucket)

      log =
        capture_log(fn ->
          assert {:ok, {:hold, :unlimited_stored_exceeds_cap}} =
                   FieldSurveyArtifactStore.reconcile_bucket(fake_jetstream({-1, 3 * @gib}))
        end)

      assert log =~ "configured=#{@gib} stored=#{3 * @gib} current=unlimited"
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end
  end

  defp put_store_config(opts) do
    Application.put_env(:serviceradar_web_ng, :field_survey_artifact_store, opts)
  end

  defp fake_jetstream(bucket_state) do
    test = self()

    fn subject, payload ->
      send(test, {:js, subject, payload})

      case {String.starts_with?(subject, "$JS.API.STREAM.INFO."), bucket_state} do
        {true, :absent} ->
          {:error, %{"code" => 404, "err_code" => 10_059, "description" => "stream not found"}}

        {true, {max_bytes, stored}} ->
          stream = String.replace_prefix(subject, "$JS.API.STREAM.INFO.", "")
          config = %{"name" => stream, "discard" => "new", "max_bytes" => max_bytes}
          {:ok, %{"config" => config, "state" => %{"bytes" => stored}}}

        {false, _state} ->
          {:ok, %{"did_create" => true}}
      end
    end
  end
end
