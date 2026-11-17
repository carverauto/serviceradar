defmodule ServiceRadar.Camera.StreamSecretScrubWorkerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Camera.StreamAddressReduction
  alias ServiceRadar.Camera.StreamSecretScrubWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  # Invented addresses: documentation IP ranges, example.com hosts, made-up aliases.
  @alias_url "rtsps://192.0.2.10:7441/AbCdEfInvented01"
  @origin "rtsps://192.0.2.10:7441"
  @worker "ServiceRadar.Camera.StreamSecretScrubWorker"

  # No peer Core node: the cluster stage is this node's own.
  @solo [core_nodes: []]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  # Every test starts from a sandbox in which a pass has scrubbed every visible row,
  # so the counts below are the test's own rows.
  setup do
    scrub_until_complete!()
    %{at_rest: StreamSecretScrubWorker.pending().at_rest_until_stage_3}
  end

  test "pending/0 and one pass agree on every kind of stored address", %{at_rest: at_rest} do
    clean_source =
      insert_source!(%{"camera_host" => "192.0.2.10", "stream" => @origin}, @alias_url)

    clean_profile =
      insert_profile!(clean_source, %{"source" => "protect-bootstrap", "fps" => 30}, @alias_url)

    alias_profile =
      insert_profile!(clean_source, %{
        "rtsps_alias" => "AbCdEf",
        "width" => 1920,
        "vendor_note" => "x"
      })

    alias_source = insert_source!(%{"rtspAlias" => "AbCdEf"})

    event_text_source =
      insert_source_text!(%{
        last_event_message: "stream #{@alias_url} moved",
        last_event_type: "https://viewer:secret@cam01.example.com/event",
        availability_reason: "probe rtsp:\\/\\/viewer:secret@cam01.example.com\\/live failed"
      })

    clean_text_source =
      insert_source_text!(%{
        last_event_message: "UniFi Protect motion event for Invented Lobby",
        last_event_type: "motion",
        availability_reason: "reachable at #{@origin}"
      })

    source_url_device = insert_device!(%{"camera_source_url" => "rtsps://192.0.2.11:7441/AbCdEf"})
    alias_device = insert_device!(%{"camera_metadata" => %{"RTSP_ALIAS" => "AbCdEf"}})
    solidus_device = insert_device!(%{"note" => "rtsps:\\/\\/192.0.2.12:7441\\/AbCdEf"})

    unicode_device =
      insert_device!(%{"note" => "https:\\u002f\\u002fviewer:pw\\u0040files.example.com\\u002fx"})

    clean_device = insert_device!(%{"camera_host" => "cam01.example.com", "stream" => @origin})

    rtsp_userinfo_status =
      insert_status!(
        %{"url" => "rtsp://viewer:secret@cam01.example.com/live"},
        "open #{@alias_url} failed"
      )

    https_userinfo_status =
      insert_status!(%{"download" => "https://viewer:secret@files.example.com/a"})

    clean_status = insert_status!(%{"stream" => @origin})

    double_encoded =
      Jason.encode!(Jason.encode!(%{"url" => @alias_url, "rtspsAlias" => "AbCdEf"}))

    deep = Enum.reduce(1..5, %{"fps" => 30}, fn _, acc -> Jason.encode!(acc) end)
    state = insert_state!(double_encoded, Jason.encode!(%{"nested" => deep}))

    assert %{
             in_scope: %{
               "camera_stream_profiles.metadata" => 1,
               "camera_sources.metadata" => 1,
               "camera_sources.last_event_message" => 1,
               "camera_sources.last_event_type" => 1,
               "camera_sources.availability_reason" => 1,
               "ocsf_devices.metadata" => 4,
               "service_status.details" => 2,
               "service_status.message" => 1,
               "service_state.message" => 1,
               "service_state.details" => 1
             },
             at_rest_until_stage_3: at_rest_after_insert
           } = StreamSecretScrubWorker.pending()

    assert at_rest_after_insert == bump(at_rest)

    assert {:snooze, _seconds} = StreamSecretScrubWorker.run_pass(1, 0, @solo)

    assert Enum.all?(StreamSecretScrubWorker.pending().in_scope, fn {_id, count} -> count == 0 end)

    # A path left in the two relay columns is reported apart and blocks nothing.
    assert StreamSecretScrubWorker.pending().at_rest_until_stage_3 == bump(at_rest)
    assert StreamSecretScrubWorker.run_pass(1, 1, @solo) == :ok

    assert profile(alias_profile) == %{
             "metadata" => %{"width" => 1920},
             "source_url_override" => nil
           }

    assert profile(clean_profile) == %{
             "metadata" => %{"source" => "protect-bootstrap", "fps" => 30},
             "source_url_override" => @alias_url
           }

    assert source(alias_source) == %{"metadata" => %{}, "source_url" => nil}

    assert source_text(event_text_source) == %{
             "last_event_message" => "stream #{@origin} moved",
             "last_event_type" => "https://cam01.example.com/event",
             "availability_reason" => "probe rtsp://cam01.example.com failed"
           }

    assert source_text(clean_text_source) == %{
             "last_event_message" => "UniFi Protect motion event for Invented Lobby",
             "last_event_type" => "motion",
             "availability_reason" => "reachable at #{@origin}"
           }

    assert source(clean_source) == %{
             "metadata" => %{"camera_host" => "192.0.2.10", "stream" => @origin},
             "source_url" => @alias_url
           }

    assert device_metadata(source_url_device) == %{}
    assert device_metadata(alias_device) == %{"camera_metadata" => %{}}
    assert device_metadata(solidus_device) == %{"note" => "rtsps://192.0.2.12:7441"}
    assert device_metadata(unicode_device) == %{"note" => "https://files.example.com/x"}

    assert device_metadata(clean_device) == %{
             "camera_host" => "cam01.example.com",
             "stream" => @origin
           }

    assert status_document(rtsp_userinfo_status) == %{"url" => "rtsp://cam01.example.com"}
    assert status_message(rtsp_userinfo_status) == "open #{@origin} failed"

    assert status_document(https_userinfo_status) == %{
             "download" => "https://files.example.com/a"
           }

    assert status_document(clean_status) == %{"stream" => @origin}

    %{"message" => message, "details" => details} = state_row(state)
    assert message |> Jason.decode!() |> Jason.decode!() == %{"url" => @origin}

    assert details |> Jason.decode!() |> Map.fetch!("nested") |> decode_times(4) ==
             StreamAddressReduction.depth_marker()
  end

  test "a pass that changed rows snoozes the same job and inserts no other job" do
    insert_source!(%{"rtsps_alias" => "AbCdEf"})
    jobs_before = worker_job_count()

    assert {:snooze, 600} = StreamSecretScrubWorker.perform(job(1, 0))
    assert worker_job_count() == jobs_before
    assert StreamSecretScrubWorker.perform(job(1, 1)) == :ok
  end

  test "a concurrent write to another column of the row does not block its scrub" do
    profile_id = insert_profile!(insert_source!(%{}), %{"rtsps_alias" => "AbCdEf", "fps" => 30})
    Process.put(:concurrent_write, {:profile_last_seen, profile_id})

    assert {:snooze, _seconds} =
             StreamSecretScrubWorker.run_pass(
               1,
               0,
               [repo: __MODULE__.ConcurrentWriterRepo] ++ @solo
             )

    assert Process.get(:concurrent_write) == nil
    assert profile(profile_id)["metadata"] == %{"fps" => 30}
    assert profile_last_seen(profile_id)
  end

  test "a row whose scrubbed column changed since it was read is skipped and the job snoozes" do
    state = insert_state!("dial #{@alias_url} failed", Jason.encode!(%{"url" => @alias_url}))
    Process.put(:concurrent_write, {:state_message, state, "progress reported by the agent"})

    assert {:snooze, _seconds} =
             StreamSecretScrubWorker.run_pass(
               1,
               0,
               [repo: __MODULE__.ConcurrentWriterRepo] ++ @solo
             )

    assert state_row(state)["message"] == "progress reported by the agent"
    assert Jason.decode!(state_row(state)["details"]) == %{"url" => @origin}

    assert StreamSecretScrubWorker.run_pass(1, 1, @solo) == :ok
  end

  test "a pass that changed and skipped nothing still snoozes while a target is pending" do
    Process.put(:insert_behind_cursor, true)

    assert {:snooze, _seconds} =
             StreamSecretScrubWorker.run_pass(1, 0, [repo: __MODULE__.BehindCursorRepo] ++ @solo)

    assert Process.get(:insert_behind_cursor) == nil
    assert StreamSecretScrubWorker.pending().in_scope["camera_sources.metadata"] == 1
  end

  test "after the configured snoozed passes the job returns the pending counts as an error" do
    insert_source!(%{"rtsps_alias" => "AbCdEf"})
    opts = [repo: __MODULE__.LosingWriterRepo] ++ @solo

    assert {:snooze, _seconds} = StreamSecretScrubWorker.run_pass(1, 999, opts)

    assert {:error, %{stage: 1, pending: pending}} =
             StreamSecretScrubWorker.run_pass(1, 1000, opts)

    assert pending["camera_sources.metadata"] == 1
    assert map_size(pending) == 10
  end

  test "targets are held while an older or unresponsive Core node is connected" do
    source_id = insert_source!(%{"rtsps_alias" => "AbCdEf"})
    nodes = [:"serviceradar_core@older.example.com", :"serviceradar_core@current.example.com"]

    for older_reply <- [{:error, {:exception, :undef, []}}, {:error, {:erpc, :timeout}}, {:ok, 0}] do
      multicall = fn ^nodes, StreamSecretScrubWorker, :scrub_stage, [], _timeout ->
        [older_reply, {:ok, 1}]
      end

      assert {:snooze, _seconds} =
               StreamSecretScrubWorker.run_pass(1, 0, core_nodes: nodes, multicall: multicall)

      assert source(source_id)["metadata"] == %{"rtsps_alias" => "AbCdEf"}
    end

    current = fn ^nodes, StreamSecretScrubWorker, :scrub_stage, [], _timeout ->
      [{:ok, 1}, {:ok, 1}]
    end

    assert {:snooze, _seconds} =
             StreamSecretScrubWorker.run_pass(1, 0, core_nodes: nodes, multicall: current)

    assert source(source_id)["metadata"] == %{}
    assert StreamSecretScrubWorker.run_pass(1, 1, core_nodes: nodes, multicall: current) == :ok
  end

  test "a stage 3 job run by stage 1 code snoozes without running a pass" do
    source_id = insert_source!(%{"rtsps_alias" => "AbCdEf"})

    assert {:snooze, _seconds} = StreamSecretScrubWorker.perform(job(3, 0))
    assert source(source_id)["metadata"] == %{"rtsps_alias" => "AbCdEf"}

    scrub_until_complete!()
    assert {:snooze, _seconds} = StreamSecretScrubWorker.perform(job(3, 1))
  end

  defmodule ConcurrentWriterRepo do
    @moduledoc false
    # Lands one write from a "live writer" just before the scrub's first update of the
    # row it names.
    def query!(sql, params) do
      case Process.get(:concurrent_write) do
        {:profile_last_seen, id} ->
          if String.contains?(sql, "UPDATE platform.camera_stream_profiles") do
            Process.delete(:concurrent_write)

            Repo.query!(
              "UPDATE platform.camera_stream_profiles SET last_seen_at = now() WHERE id = $1::text::uuid",
              [id]
            )
          end

        {:state_message, id, message} ->
          if String.contains?(sql, "UPDATE platform.service_state") and
               String.contains?(sql, "SET message") do
            Process.delete(:concurrent_write)

            Repo.query!(
              "UPDATE platform.service_state SET message = $2 WHERE id = $1::text::uuid",
              [id, message]
            )
          end

        nil ->
          :ok
      end

      Repo.query!(sql, params)
    end
  end

  defmodule BehindCursorRepo do
    @moduledoc false
    # Once the camera_sources target has been scanned, an older replica writes a
    # dirty source row the pass cannot see any more.
    def query!(sql, params) do
      if Process.get(:insert_behind_cursor) &&
           String.contains?(sql, "FROM platform.service_state") do
        Process.delete(:insert_behind_cursor)

        Repo.query!(
          """
          INSERT INTO platform.camera_sources (device_uid, vendor, vendor_camera_id, metadata)
          VALUES ($1, 'invented', $1, '{"rtspsAlias": "AbCdEf"}'::jsonb)
          """,
          ["sr:scrub-behind-#{System.unique_integer([:positive])}"]
        )
      end

      Repo.query!(sql, params)
    end
  end

  defmodule LosingWriterRepo do
    @moduledoc false
    # Every compare-and-set loses, as if a live writer changed each column first.
    def query!(sql, params) do
      if String.starts_with?(String.trim_leading(sql), "UPDATE") do
        %{num_rows: 0}
      else
        Repo.query!(sql, params)
      end
    end
  end

  defp scrub_until_complete!(attempts \\ 4) do
    case StreamSecretScrubWorker.run_pass(1, 0, @solo) do
      :ok -> :ok
      {:snooze, _seconds} when attempts > 1 -> scrub_until_complete!(attempts - 1)
      other -> flunk("the sandbox did not scrub clean: #{inspect(other)}")
    end
  end

  defp bump(at_rest) do
    at_rest
    |> Map.update!("camera_sources.source_url", &(&1 + 1))
    |> Map.update!("camera_stream_profiles.source_url_override", &(&1 + 1))
  end

  defp decode_times(value, 0), do: value
  defp decode_times(value, times), do: value |> Jason.decode!() |> decode_times(times - 1)

  defp job(stage, snoozed),
    do: %Oban.Job{args: %{"stage" => stage}, meta: %{"snoozed" => snoozed}}

  defp worker_job_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM platform.oban_jobs WHERE worker = $1", [@worker])

    count
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp insert_source!(metadata, source_url \\ nil) do
    camera_id = unique("scrub-camera")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.camera_sources (device_uid, vendor, vendor_camera_id, metadata, source_url)
        VALUES ($1, 'invented', $1, $2::jsonb, $3)
        RETURNING id::text
        """,
        [camera_id, metadata, source_url]
      )

    id
  end

  defp insert_source_text!(text) do
    camera_id = unique("scrub-camera")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.camera_sources
          (device_uid, vendor, vendor_camera_id, last_event_message, last_event_type,
           availability_reason)
        VALUES ($1, 'invented', $1, $2, $3, $4)
        RETURNING id::text
        """,
        [camera_id, text.last_event_message, text.last_event_type, text.availability_reason]
      )

    id
  end

  defp insert_profile!(source_id, metadata, source_url_override \\ nil) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.camera_stream_profiles
          (camera_source_id, profile_name, metadata, source_url_override)
        VALUES ($1::text::uuid, $2, $3::jsonb, $4)
        RETURNING id::text
        """,
        [source_id, unique("profile"), metadata, source_url_override]
      )

    id
  end

  defp insert_device!(metadata) do
    uid = unique("sr:scrub-device")

    Repo.query!(
      "INSERT INTO platform.ocsf_devices (uid, type_id, metadata) VALUES ($1, 7, $2::jsonb)",
      [uid, metadata]
    )

    uid
  end

  defp insert_status!(document, message \\ nil) do
    gateway_id = unique("scrub-gateway")

    Repo.query!(
      """
      INSERT INTO platform.service_status
        (timestamp, gateway_id, service_name, available, message, details)
      VALUES (now(), $1, 'invented-camera-plugin', true, $2, $3)
      """,
      [gateway_id, message, Jason.encode!(document)]
    )

    gateway_id
  end

  defp insert_state!(message, details) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO platform.service_state
          (agent_id, gateway_id, partition, service_type, service_name, available,
           last_observed_at, message, details)
        VALUES ($1, $1, 'default', 'plugin', 'invented-camera-plugin', true,
                now() AT TIME ZONE 'utc', $2, $3)
        RETURNING id::text
        """,
        [unique("scrub-agent"), message, details]
      )

    id
  end

  defp profile(id) do
    one!(
      "SELECT metadata, source_url_override FROM platform.camera_stream_profiles WHERE id = $1::text::uuid",
      [id]
    )
  end

  defp profile_last_seen(id) do
    one!("SELECT last_seen_at FROM platform.camera_stream_profiles WHERE id = $1::text::uuid", [
      id
    ])[
      "last_seen_at"
    ]
  end

  defp source_text(id) do
    one!(
      """
      SELECT last_event_message, last_event_type, availability_reason
      FROM platform.camera_sources WHERE id = $1::text::uuid
      """,
      [id]
    )
  end

  defp source(id) do
    one!("SELECT metadata, source_url FROM platform.camera_sources WHERE id = $1::text::uuid", [
      id
    ])
  end

  defp device_metadata(uid) do
    one!("SELECT metadata FROM platform.ocsf_devices WHERE uid = $1", [uid])["metadata"]
  end

  defp status_document(gateway_id) do
    Jason.decode!(
      one!("SELECT details FROM platform.service_status WHERE gateway_id = $1", [gateway_id])[
        "details"
      ]
    )
  end

  defp status_message(gateway_id) do
    one!("SELECT message FROM platform.service_status WHERE gateway_id = $1", [gateway_id])[
      "message"
    ]
  end

  defp state_row(id) do
    one!("SELECT message, details FROM platform.service_state WHERE id = $1::text::uuid", [id])
  end

  defp one!(sql, params) do
    %{columns: columns, rows: [row]} = Repo.query!(sql, params)
    columns |> Enum.zip(row) |> Map.new()
  end
end
