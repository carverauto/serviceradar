defmodule ServiceRadar.Inventory.ExposureTransitionRelayTest do
  @moduledoc """
  The outbox relay deletes a transition only after the stream acknowledged it,
  publishes it under its sequence as the JetStream message id, and reports
  stream freshness without treating unavailable status as healthy.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias Serviceradar.Metric.V1.MetricBatch
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "acknowledged transitions leave the outbox; a refused one stays and the stream is ensured" do
    unique = System.unique_integer([:positive])
    accepted_device = "sr:relay-accepted-#{unique}"
    refused_device = "sr:relay-refused-#{unique}"
    insert_actionable_assessment!(accepted_device, unique)
    insert_actionable_assessment!(refused_device, unique)
    parent = self()

    publish = fn subject, body, opts ->
      payload = Jason.decode!(body)

      if payload["device_uid"] in [accepted_device, refused_device],
        do: send(parent, {:published, subject, payload, opts[:msg_id]})

      if payload["device_uid"] == refused_device, do: {:error, :timeout}, else: :ok
    end

    ensure_stream = fn _opts ->
      send(parent, :stream_ensured)
      :ok
    end

    assert {:ok, %{relayed: relayed, failed: 1}} =
             ExposureTransitionRelay.relay_once(
               batch_size: 10_000,
               publish: publish,
               ensure_stream: ensure_stream
             )

    assert relayed >= 1
    assert_received :stream_ensured

    published =
      for _attempt <- 1..2, into: %{} do
        assert_received {:published, subject, payload, msg_id}
        {payload["device_uid"], {subject, payload, msg_id}}
      end

    for device_uid <- [accepted_device, refused_device] do
      {subject, payload, msg_id} = Map.fetch!(published, device_uid)
      assert subject == ExposureTransitionRelay.subject(device_uid)
      assert subject =~ ~r/^vulnerability\.assessment\.transitions\.([0-9]|1[0-5])$/
      assert payload["state"] == "active"
      assert msg_id == "exposure-transition-#{payload["transition_seq"]}"
    end

    assert outbox_devices([accepted_device, refused_device]) == [refused_device]
  end

  @tag :tmp_dir
  test "real stream retention drift degrades health once and recovery emits retained age metrics",
       ctx do
    enable_health_tracking!()

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      metrics_stream!(conn)

      assert %{"config" => config} =
               ExposureBroker.request(conn, "$JS.API.STREAM.CREATE.EXPOSURE_TRANSITIONS", %{
                 name: "EXPOSURE_TRANSITIONS",
                 subjects: ["vulnerability.assessment.transitions.>"],
                 max_age: 0,
                 max_bytes: ExposureTransitionRelay.default_max_bytes()
               })

      relay = health_relay!()

      try do
        assert %{"seq" => 1} =
                 ExposureBroker.request(
                   conn,
                   ExposureTransitionRelay.subject("sr:health-example"),
                   %{
                     synthetic: true
                   }
                 )

        report!(relay)

        assert {:ok, %{new_state: :degraded} = degraded} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert degraded.reason == :stream_retention_unbounded
        assert degraded.metadata["max_age_seconds"] == 0

        report!(relay)

        assert {:ok, repeated} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert repeated.id == degraded.id

        assert %{"config" => %{}} =
                 ExposureBroker.request(
                   conn,
                   "$JS.API.STREAM.UPDATE.EXPOSURE_TRANSITIONS",
                   Map.put(config, "max_age", 691_200_000_000_000)
                 )

        report!(relay)

        assert {:ok, over_limit} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert over_limit.id == degraded.id
        assert retained_metrics!(conn)["exposure_transitions_stream_max_age_seconds"] == 691_200.0

        assert %{"config" => %{"max_age" => 604_800_000_000_000}} =
                 ExposureBroker.request(
                   conn,
                   "$JS.API.STREAM.UPDATE.EXPOSURE_TRANSITIONS",
                   Map.put(config, "max_age", 604_800_000_000_000)
                 )

        report!(relay)

        assert {:ok, recovered} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert recovered.new_state == :healthy
        assert recovered.reason == :stream_freshness_recovered
        assert recovered.metadata["oldest_age_seconds"] >= 0

        metrics = retained_metrics!(conn)
        assert metrics["exposure_transitions_stream_oldest_age_seconds"] >= 0
        assert metrics["exposure_transitions_stream_max_age_seconds"] == 604_800.0

        assert %{"success" => true} =
                 ExposureBroker.request(conn, "$JS.API.STREAM.DELETE.EXPOSURE_TRANSITIONS", %{})

        report!(relay)

        assert {:ok, missing} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert missing.new_state == :degraded
        assert missing.reason == :stream_health_unavailable

        refute Map.has_key?(
                 retained_metrics!(conn),
                 "exposure_transitions_stream_oldest_age_seconds"
               )
      after
        stop_supervised!(ExposureTransitionRelay)
      end
    end)
  end

  @tag :tmp_dir
  test "reported old messages and invalid timestamps cannot produce healthy stream telemetry",
       ctx do
    enable_health_tracking!()

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      metrics_stream!(conn)
      timestamp = DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), minute: -10_081))

      response = %{
        "config" => %{
          "subjects" => ["vulnerability.assessment.transitions.>"],
          "max_bytes" => ExposureTransitionRelay.default_max_bytes(),
          "max_age" => 604_800_000_000_000
        },
        "state" => %{"messages" => 1, "bytes" => 1, "first_ts" => timestamp}
      }

      replies = start_supervised!({Agent, fn -> response end})
      server = start_supervised!({Task, fn -> stream_info_replies(conn, replies) end})

      assert {:ok, _} =
               Gnat.sub(
                 conn,
                 server,
                 "$JS.EXPOSURE_HEALTH_TEST.API.STREAM.INFO.EXPOSURE_TRANSITIONS"
               )

      relay = health_relay!(domain: "EXPOSURE_HEALTH_TEST")

      try do
        report!(relay)

        assert {:ok, %{new_state: :degraded} = old} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert old.reason == :stream_age_exceeded
        assert old.metadata["oldest_age_seconds"] > 604_800
        assert retained_metrics!(conn)["exposure_transitions_stream_oldest_age_seconds"] > 604_800

        Agent.update(replies, &put_in(&1, ["state", "messages"], 0))
        report!(relay)
        assert {:ok, empty} = HealthTracker.current_status(:custom, "exposure_transitions_stream")
        assert empty.new_state == :healthy
        assert retained_metrics!(conn)["exposure_transitions_stream_oldest_age_seconds"] == 0.0

        Agent.update(replies, fn value ->
          %{value | "state" => %{"messages" => 1, "bytes" => 1, "first_ts" => "invalid"}}
        end)

        report!(relay)

        assert {:ok, invalid} =
                 HealthTracker.current_status(:custom, "exposure_transitions_stream")

        assert invalid.new_state == :degraded
        assert invalid.reason == :stream_health_unavailable

        refute Map.has_key?(
                 retained_metrics!(conn),
                 "exposure_transitions_stream_oldest_age_seconds"
               )
      after
        stop_supervised!(ExposureTransitionRelay)
        stop_supervised!(Task)
      end
    end)
  end

  defp enable_health_tracking! do
    previous = Application.get_env(:serviceradar_core, :repo_enabled)
    Application.put_env(:serviceradar_core, :repo_enabled, true)
    on_exit(fn -> Application.put_env(:serviceradar_core, :repo_enabled, previous) end)
  end

  defp health_relay!(opts \\ []) do
    start_supervised!(
      {ExposureTransitionRelay,
       Keyword.merge(
         [
           name: __MODULE__.HealthRelay,
           poll_interval_ms: 3_600_000,
           report_interval_ms: 3_600_000
         ],
         opts
       )}
    )
  end

  defp report!(relay) do
    send(relay, :report)
    :sys.get_state(relay, 30_000)
    :ok
  end

  defp metrics_stream!(conn) do
    assert %{"config" => %{}} =
             ExposureBroker.request(conn, "$JS.API.STREAM.CREATE.EXPOSURE_HEALTH_METRICS", %{
               name: "EXPOSURE_HEALTH_METRICS",
               subjects: ["metrics.exposure_transitions"]
             })
  end

  defp retained_metrics!(conn) do
    assert %{"message" => %{"data" => encoded}} =
             ExposureBroker.request(conn, "$JS.API.STREAM.MSG.GET.EXPOSURE_HEALTH_METRICS", %{
               last_by_subj: "metrics.exposure_transitions"
             })

    encoded
    |> Base.decode64!()
    |> MetricBatch.decode()
    |> Map.fetch!(:metrics)
    |> Map.new(fn metric -> {metric.name, hd(metric.points).value} end)
  end

  defp stream_info_replies(conn, replies) do
    receive do
      {:msg, %{reply_to: subject}} ->
        :ok = Gnat.pub(conn, subject, Jason.encode!(Agent.get(replies, & &1)))
        stream_info_replies(conn, replies)
    end
  end

  defp outbox_devices(device_uids) do
    Repo.all(
      from(o in "exposure_transition_outbox",
        where: o.device_uid in ^device_uids,
        select: o.device_uid
      ),
      prefix: "platform"
    )
  end

  defp insert_actionable_assessment!(device_uid, unique) do
    endpoint_package_ref = Ecto.UUID.dump!(Ecto.UUID.generate())
    now = ~N[2026-01-01 00:00:00]

    Repo.insert_all(
      "endpoint_packages",
      [
        %{
          id: endpoint_package_ref,
          coordinate_key: "relay-#{device_uid}",
          cpes: [],
          package_manager: "dpkg",
          name: "examplelib",
          version: "1.0.0",
          source_scope: "host",
          metadata: %{}
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "endpoint_vulnerability_assessments",
      [
        %{
          device_uid: device_uid,
          package_identity_key: "pkgkey:relay:#{unique}",
          endpoint_package_ref: endpoint_package_ref,
          cve_id: "CVE-2024-0007",
          status: "active",
          assessment: "confirmed",
          disposition: "affected",
          applicability_reason: "synthetic",
          installed_version: "1.0.0",
          first_seen_at: now,
          last_seen_at: now
        }
      ],
      prefix: "platform"
    )
  end
end
