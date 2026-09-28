defmodule ServiceRadar.Observability.ThreatIntelRawPayloadStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.ThreatIntelRawPayloadStore

  @gib 1_073_741_824

  test "builds stable sanitized object keys from payload metadata" do
    payload = ~s({"objects":[{"id":"indicator--1"}]})

    key =
      ThreatIntelRawPayloadStore.object_key(
        %{
          source: "alienvault_otx",
          collection_id: "otx:pulses/subscribed",
          observed_at: ~U[2026-04-28 01:02:03Z]
        },
        payload
      )

    assert key ==
             "alienvault_otx/otx:pulses-subscribed/20260428T010203Z-#{ThreatIntelRawPayloadStore.sha256(payload)}.json"
  end

  describe "reconcile_bucket/1" do
    setup do
      original = Application.get_env(:serviceradar_core, ThreatIntelRawPayloadStore)
      bucket = "threat_intel_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:serviceradar_core, ThreatIntelRawPayloadStore)
        else
          Application.put_env(:serviceradar_core, ThreatIntelRawPayloadStore, original)
        end
      end)

      {:ok, bucket: bucket, stream: "OBJ_#{bucket}"}
    end

    test "creates an absent bucket with the 1 GiB default cap",
         %{bucket: bucket, stream: stream} do
      put_config(jetstream_bucket: bucket, jetstream_replicas: 3)

      assert {:ok, :create} = ThreatIntelRawPayloadStore.reconcile_bucket(fake_jetstream(:absent))

      create_subject = "$JS.API.STREAM.CREATE.#{stream}"
      assert_received {:js, ^create_subject, payload}
      created = Jason.decode!(payload)
      assert created["max_bytes"] == @gib
      assert created["discard"] == "new"
      assert created["num_replicas"] == 3
    end

    test "caps an existing unlimited bucket whose data fits", %{bucket: bucket, stream: stream} do
      put_config(jetstream_bucket: bucket, jetstream_max_bucket_size: 2 * @gib)

      assert {:ok, {:update, max_bytes}} =
               ThreatIntelRawPayloadStore.reconcile_bucket(fake_jetstream({-1, div(@gib, 10)}))

      assert max_bytes == 2 * @gib
      update_subject = "$JS.API.STREAM.UPDATE.#{stream}"
      assert_received {:js, ^update_subject, payload}
      assert Jason.decode!(payload)["max_bytes"] == 2 * @gib
    end

    test "leaves an unlimited bucket holding more than the cap unlimited and logs it",
         %{bucket: bucket} do
      put_config(jetstream_bucket: bucket)

      log =
        capture_log(fn ->
          assert {:ok, {:hold, :unlimited_stored_exceeds_cap}} =
                   ThreatIntelRawPayloadStore.reconcile_bucket(fake_jetstream({-1, 3 * @gib}))
        end)

      assert log =~ "configured=#{@gib} stored=#{3 * @gib} current=unlimited"
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end
  end

  defp put_config(opts) do
    Application.put_env(:serviceradar_core, ThreatIntelRawPayloadStore, opts)
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
