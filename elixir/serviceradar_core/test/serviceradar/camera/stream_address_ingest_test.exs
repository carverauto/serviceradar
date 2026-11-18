defmodule ServiceRadar.Camera.StreamAddressIngestTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Camera.StreamSecretScrubWorker
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.PluginResultIngestorTestSupport
  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  # Invented camera inventory: documentation IP range, made-up alias and ids.
  @alias "AbCdEfInvented02"
  @alias_url "rtsps://192.0.2.10:7441/#{@alias}"
  @origin "rtsps://192.0.2.10:7441"
  @solo [core_nodes: []]
  @state_reserved_keys [
    "_serviceradar_plugin_result",
    "downstream_ingest",
    "reported_result",
    "status",
    "summary"
  ]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    scrub_until_complete!()
    suffix = System.unique_integer([:positive])
    device_uid = "sr:camera-invented-#{suffix}"
    assignment_id = insert_plugin_assignment!(suffix)

    %{
      device_uid: device_uid,
      camera_id: "invented-camera-#{suffix}",
      assignment_id: assignment_id,
      status: %{
        source: "plugin-result",
        agent_id: "invented-agent-#{suffix}",
        gateway_id: "invented-gateway-#{suffix}",
        partition: "default",
        service_type: "plugin",
        service_name: "invented-camera-inventory-#{suffix}",
        plugin_provenance: %{"assignment_id" => assignment_id}
      },
      handlers: [
        {InventoryIngestor, resolve_device_uid: fn _descriptor, _status, _actor -> device_uid end}
      ]
    }
  end

  # The camera-streaming scenario "Old plugin and Core after cutover".
  test "an address from a plugin that predates resolution is stored nowhere; its origin and discovering assignment are",
       ctx do
    assert in_scope_zero?()

    assert :ok =
             PluginResultIngestor.ingest_durable(report(ctx, observed_at()), ctx.status,
               handlers: ctx.handlers
             )

    assert in_scope_zero?()

    source = source(ctx)
    assert source["source_url"] == nil
    assert source["discovery_assignment_id"] == ctx.assignment_id

    for column <- ["last_event_message", "last_event_type", "availability_reason"] do
      assert source[column] == "stream #{@origin} moved"
    end

    assert source["metadata"] == %{"controller_host" => "192.0.2.10", "stream" => @origin}

    assert profile(ctx, "High") == %{
             "source_url_override" => nil,
             "source_origin" => @origin,
             "metadata" => %{"source" => "protect-bootstrap", "width" => 1920}
           }

    device_metadata = device_metadata(ctx)
    refute Map.has_key?(device_metadata, "camera_source_url")
    assert device_metadata["camera_metadata"] == source["metadata"]

    for text <- stored_plugin_texts(ctx) do
      refute text =~ @alias
      refute text =~ ~r/rtsps?_?alias/i
    end

    assert Enum.any?(stored_plugin_texts(ctx), &(&1 =~ @origin))
  end

  # The camera-streaming scenario "New plugin and Core after cutover": the plugin saw
  # the cutover key and reports only an origin.
  test "an origin-only report sets the profile origin, and a later report without provenance keeps the assignment",
       ctx do
    origin_only = %{
      "status" => "OK",
      "summary" => "1 camera discovered",
      "camera_descriptors" => [
        %{
          "device_uid" => ctx.device_uid,
          "vendor" => "ubiquiti",
          "camera_id" => ctx.camera_id,
          "display_name" => "Invented Lobby",
          # A payload cannot name its own assignment; only the host stamp counts.
          "discovery_assignment_id" => Ecto.UUID.generate(),
          "stream_profiles" => [
            %{
              "profile_name" => "High",
              "vendor_profile_id" => "high",
              "source_origin" => @origin,
              "rtsp_transport" => "tcp"
            }
          ]
        }
      ]
    }

    assert :ok =
             PluginResultIngestor.ingest_durable(
               Map.put(origin_only, "observed_at", DateTime.to_iso8601(observed_at())),
               ctx.status,
               handlers: ctx.handlers
             )

    assert %{"source_origin" => @origin, "source_url_override" => nil} = profile(ctx, "High")
    assert source(ctx)["discovery_assignment_id"] == ctx.assignment_id

    assert :ok =
             PluginResultIngestor.ingest_durable(
               Map.put(origin_only, "observed_at", DateTime.to_iso8601(DateTime.utc_now())),
               Map.delete(ctx.status, :plugin_provenance),
               handlers: ctx.handlers
             )

    assert source(ctx)["discovery_assignment_id"] == ctx.assignment_id
    assert in_scope_zero?()
  end

  test "a result stored before reduction and then scrubbed is matched, not duplicated, when redelivered",
       ctx do
    observed_at = observed_at()
    report = report(ctx, observed_at)

    assert :ok = PluginResultIngestor.ingest_durable(report, ctx.status, handlers: ctx.handlers)
    store_as_before_reduction!(ctx, report, observed_at)

    assert %{"service_status.details" => status_pending, "service_state.details" => state_pending} =
             StreamSecretScrubWorker.pending().in_scope

    assert status_pending >= 1 and state_pending >= 1

    scrub_until_complete!()
    assert :ok = PluginResultIngestor.ingest_durable(report, ctx.status, handlers: ctx.handlers)

    assert [_one_reported_row] = reported_rows(ctx, observed_at)
    assert in_scope_zero?()

    for text <- stored_plugin_texts(ctx), do: refute(text =~ @alias)
  end

  defp report(ctx, observed_at) do
    %{
      "status" => "OK",
      "summary" => "1 camera discovered",
      "observed_at" => DateTime.to_iso8601(observed_at),
      "camera_descriptors" => [
        %{
          "device_uid" => ctx.device_uid,
          "vendor" => "ubiquiti",
          "camera_id" => ctx.camera_id,
          "display_name" => "Invented Lobby",
          "source_url" => @alias_url,
          "metadata" => %{"controller_host" => "192.0.2.10", "stream" => @alias_url},
          "stream_profiles" => [
            %{
              "profile_name" => "High",
              "vendor_profile_id" => "invented-channel-0",
              "source_url_override" => @alias_url,
              "rtsp_transport" => "tcp",
              "codec_hint" => "h264",
              "metadata" => %{
                "source" => "protect-bootstrap",
                "width" => 1920,
                "rtsps_alias" => @alias,
                "vendor_note" => "not in the allowlist"
              }
            }
          ]
        }
      ],
      "streams" => [%{"url" => @alias_url}],
      "events" => [
        %{"message" => "stream #{@alias_url} moved", "time" => DateTime.to_iso8601(observed_at)}
      ],
      "channels" => [%{"rtspsAlias" => @alias}]
    }
  end

  defp observed_at,
    do: DateTime.utc_now() |> DateTime.shift(second: -30) |> DateTime.truncate(:microsecond)

  # Rewrites the rows the report produced to what Core wrote before entry reduction:
  # the unreduced payload with digests computed over it.
  defp store_as_before_reduction!(ctx, report, observed_at) do
    marker_key = PluginResultReportedMarker.marker_key()
    digest = PluginResultReportedMarker.payload_digest(report)

    [[timestamp, _available, _message, details]] = reported_rows(ctx, observed_at)
    marker = details |> Jason.decode!() |> Map.fetch!(marker_key)

    Repo.query!(
      """
      UPDATE platform.service_status SET details = $4
      WHERE timestamp = $1 AND gateway_id = $2 AND service_name = $3
      """,
      [
        timestamp,
        ctx.status.gateway_id,
        ctx.status.service_name,
        Jason.encode!(Map.put(report, marker_key, Map.put(marker, "payload_digest", digest)))
      ]
    )

    %{"id" => id} = state = state_row(ctx)

    unreduced =
      Map.new(["message", "details"], fn column ->
        case Jason.decode(state[column] || "") do
          {:ok, %{"downstream_ingest" => downstream} = document} ->
            {column,
             document
             |> Map.merge(Map.drop(report, @state_reserved_keys))
             |> Map.put("reported_result", report)
             |> Map.put("downstream_ingest", Map.put(downstream, "payload_digest", digest))
             |> Jason.encode!()}

          _other ->
            {column, state[column]}
        end
      end)

    Repo.query!(
      "UPDATE platform.service_state SET message = $2, details = $3 WHERE id = $1::text::uuid",
      [id, unreduced["message"], unreduced["details"]]
    )
  end

  defp scrub_until_complete!(attempts \\ 4) do
    case StreamSecretScrubWorker.run_pass(3, 0, @solo) do
      :ok -> :ok
      {:snooze, _seconds} when attempts > 1 -> scrub_until_complete!(attempts - 1)
      other -> flunk("the sandbox did not scrub clean: #{inspect(other)}")
    end
  end

  defp in_scope_zero? do
    Enum.all?(StreamSecretScrubWorker.pending().in_scope, fn {_target, count} -> count == 0 end)
  end

  defp reported_rows(ctx, observed_at) do
    observation = DateTime.to_iso8601(observed_at)

    Enum.filter(PluginResultIngestorTestSupport.reported_history_rows(ctx.status), fn row ->
      row
      |> List.last()
      |> Jason.decode!()
      |> get_in(["_serviceradar_plugin_result", "observation_timestamp"]) ==
        observation
    end)
  end

  defp stored_plugin_texts(ctx) do
    history =
      Enum.flat_map(PluginResultIngestorTestSupport.history_rows(ctx.status), fn [
                                                                                   _ts,
                                                                                   _available,
                                                                                   message,
                                                                                   details
                                                                                 ] ->
        [message, details]
      end)

    state = state_row(ctx)
    Enum.filter(history ++ [state["message"], state["details"]], &is_binary/1)
  end

  defp state_row(ctx) do
    one!(
      """
      SELECT id::text AS id, message, details FROM platform.service_state
      WHERE agent_id = $1 AND gateway_id = $2 AND service_name = $3
      """,
      [ctx.status.agent_id, ctx.status.gateway_id, ctx.status.service_name]
    )
  end

  defp source(ctx) do
    one!(
      """
      SELECT source_url, discovery_assignment_id::text AS discovery_assignment_id, metadata,
             last_event_message, last_event_type, availability_reason
      FROM platform.camera_sources WHERE vendor = 'ubiquiti' AND vendor_camera_id = $1
      """,
      [ctx.camera_id]
    )
  end

  defp profile(ctx, profile_name) do
    one!(
      """
      SELECT p.source_url_override, p.source_origin, p.metadata
      FROM platform.camera_stream_profiles p
      JOIN platform.camera_sources s ON s.id = p.camera_source_id
      WHERE s.vendor = 'ubiquiti' AND s.vendor_camera_id = $1 AND p.profile_name = $2
      """,
      [ctx.camera_id, profile_name]
    )
  end

  # The discovering assignment the host stamps on the result; invented package. The
  # package is named like the status's service, which provenance resolves it to.
  defp insert_plugin_assignment!(suffix) do
    plugin_id = "invented-camera-plugin-#{suffix}"
    package_name = "invented-camera-inventory-#{suffix}"

    Repo.query!("INSERT INTO platform.plugins (plugin_id, name) VALUES ($1, $1)", [plugin_id])

    %{rows: [[package_id]]} =
      Repo.query!(
        """
        INSERT INTO platform.plugin_packages (plugin_id, name, version, entrypoint, outputs)
        VALUES ($1, $2, '1.0.0', 'run_check', 'serviceradar.plugin_result.v1')
        RETURNING id
        """,
        [plugin_id, package_name]
      )

    %{rows: [[assignment_id]]} =
      Repo.query!(
        """
        INSERT INTO platform.plugin_assignments (agent_uid, plugin_package_id, plugin_id, partition_id)
        VALUES ($1, $2, $3, 'default')
        RETURNING id::text
        """,
        ["invented-agent-#{suffix}", package_id, plugin_id]
      )

    assignment_id
  end

  defp device_metadata(ctx) do
    one!("SELECT metadata FROM platform.ocsf_devices WHERE uid = $1", [ctx.device_uid])[
      "metadata"
    ]
  end

  defp one!(sql, params) do
    %{columns: columns, rows: [row]} = Repo.query!(sql, params)
    columns |> Enum.zip(row) |> Map.new()
  end
end
