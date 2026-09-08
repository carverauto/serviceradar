defmodule ServiceRadar.Inventory.EndpointInventoryHistory do
  @moduledoc false

  alias ServiceRadar.Inventory.EndpointInventoryPackageSet
  alias ServiceRadar.Inventory.EndpointInventoryPayload, as: Payload
  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Repo

  require Logger

  @package_event_added "added"
  @package_event_removed "removed"
  @package_event_version_changed "version_changed"
  @package_change_signal_schema_version "serviceradar.endpoint_inventory.package_change.v1"

  def record_changed(scan_ref, current, previous_packages, context) do
    if record_changed?(context) do
      package_events =
        EndpointInventoryPackageSet.diff_events(previous_packages, context.packages)

      {package_event_count, package_event_rows} =
        insert_package_events(scan_ref, current, package_events, context)

      apply_current_count_changes(package_events, context)

      insert_scan_history(scan_ref, current, package_event_count, context)

      %{
        scan_history_recorded?: true,
        package_event_count: package_event_count,
        package_change_signals: Enum.map(package_event_rows, &package_change_signal/1)
      }
    else
      %{scan_history_recorded?: false, package_event_count: 0, package_change_signals: []}
    end
  end

  def publish_package_change_signals([], _opts), do: 0

  def publish_package_change_signals(signals, opts) do
    publisher = Keyword.get(opts, :causal_signal_publisher, {Connection, :publish, []})

    Enum.reduce(signals, 0, fn %{subject: subject, payload: payload}, count ->
      encoded = Jason.encode!(payload)

      case publish_causal_signal(publisher, subject, encoded) do
        :ok ->
          count + 1

        {:error, reason} ->
          Logger.warning(
            "Endpoint inventory causal signal publish failed: subject=#{subject} reason=#{inspect(reason)}"
          )

          count
      end
    end)
  end

  defp record_changed?(context) do
    context.successful_scan? and not context.package_replacement_noop?
  end

  defp insert_scan_history(scan_ref, current, package_event_count, context) do
    row = %{
      scan_time: changed_scan_time(context),
      scan_ref: scan_ref,
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      scan_id: context.scan_id,
      collector_name: context.collector_name,
      collector_version: context.collector_version,
      state: context.state,
      coverage_state: context.coverage_state,
      package_count: context.package_count,
      enabled_sources: context.enabled_sources,
      manager_counts: context.manager_counts,
      source_summaries: context.source_summaries,
      artifact_count: if(is_nil(context.artifact_hash), do: 0, else: 1),
      package_set_hash: context.package_set_hash,
      previous_package_set_hash: Map.get(current || %{}, :package_set_hash),
      server_package_set_hash: context.server_package_set_hash,
      artifact_hash: context.artifact_hash,
      hash_algorithm: context.hash_algorithm,
      upload_reason: context.upload_reason,
      package_set_hash_mismatch: context.package_set_hash_mismatch?,
      package_event_count: package_event_count,
      metadata: scan_history_metadata(current, context),
      inserted_at: context.now
    }

    Repo.insert_all("endpoint_inventory_scan_history", [row], prefix: "platform")
  end

  defp insert_package_events(_scan_ref, _current, [], _context), do: {0, []}

  defp insert_package_events(scan_ref, current, package_events, context) do
    scan_time = changed_scan_time(context)

    rows =
      Enum.map(package_events, fn event ->
        package_event_row(scan_ref, current, event, scan_time, context)
      end)

    {count, _rows} =
      Repo.insert_all("endpoint_inventory_package_events", rows,
        prefix: "platform",
        on_conflict: :nothing,
        conflict_target: [:scan_time, :event_id]
      )

    {count, rows}
  end

  defp package_change_signal(row) do
    event_type = Map.fetch!(row, :event_type)

    %{
      subject: "signals.analytics.inventory.#{event_type}",
      payload: %{
        "schema_version" => @package_change_signal_schema_version,
        "event_id" => row.event_id,
        "signal_type" => "inventory",
        "signal_domain" => "inventory",
        "event_type" => event_type,
        "timestamp" => DateTime.to_iso8601(row.scan_time),
        "observed_at" => DateTime.to_iso8601(row.scan_time),
        "severity" => "informational",
        "message" => package_change_message(event_type, row),
        "agent_id" => row.agent_id,
        "device_uid" => row.device_uid,
        "device_id" => row.device_uid,
        "scan_id" => row.scan_id,
        "package_set_hash" => row.package_set_hash,
        "previous_package_set_hash" => row.previous_package_set_hash,
        "artifact_hash" => row.artifact_hash,
        "package" => package_change_package(row),
        "previous_package" => previous_package(row)
      }
    }
  end

  defp package_change_message(@package_event_added, row),
    do: "endpoint package added: #{row.name}"

  defp package_change_message(@package_event_removed, row),
    do: "endpoint package removed: #{row.name}"

  defp package_change_message(@package_event_version_changed, row),
    do: "endpoint package version changed: #{row.name}"

  defp package_change_message(_event_type, row), do: "endpoint package changed: #{row.name}"

  defp package_change_package(row) do
    Payload.compact_map(%{
      "package_manager" => row.package_manager,
      "ecosystem" => row.ecosystem,
      "name" => row.name,
      "architecture" => row.architecture,
      "version" => row.version,
      "previous_version" => row.previous_version,
      "new_version" => row.new_version,
      "purl" => row.purl,
      "purl_canonical" => row.purl_canonical,
      "previous_purl" => row.previous_purl,
      "previous_purl_canonical" => row.previous_purl_canonical,
      "cpes" => row.cpes || [],
      "coordinate_hash" => row.coordinate_hash
    })
  end

  defp previous_package(%{
         previous_version: nil,
         previous_purl: nil,
         previous_purl_canonical: nil
       }), do: nil

  defp previous_package(row) do
    Payload.compact_map(%{
      "package_manager" => row.package_manager,
      "ecosystem" => row.ecosystem,
      "name" => row.name,
      "architecture" => row.architecture,
      "version" => row.previous_version,
      "purl" => row.previous_purl,
      "purl_canonical" => row.previous_purl_canonical
    })
  end

  defp publish_causal_signal(fun, subject, payload) when is_function(fun, 2) do
    fun.(subject, payload)
  end

  defp publish_causal_signal({module, function, extra_args}, subject, payload) do
    apply(module, function, [subject, payload | extra_args])
  end

  defp package_event_row(scan_ref, current, event, scan_time, context) do
    package = Map.get(event, :package) || Map.fetch!(event, :previous_package)
    previous_package = Map.get(event, :previous_package)
    event_type = Map.fetch!(event, :event_type)
    event_hash = EndpointInventoryPackageSet.event_coordinate_hash(event)

    %{
      event_id: package_event_id(context, event_type, event_hash),
      scan_time: scan_time,
      scan_ref: scan_ref,
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      scan_id: context.scan_id,
      event_type: event_type,
      package_manager: package.package_manager,
      ecosystem: package.ecosystem,
      name: package.name,
      architecture: package.architecture,
      version: package.version,
      previous_version: Map.get(previous_package || %{}, :version),
      new_version: Map.get(event[:package] || %{}, :version),
      purl: package.purl,
      purl_canonical: package.purl_canonical,
      previous_purl: Map.get(previous_package || %{}, :purl),
      previous_purl_canonical: Map.get(previous_package || %{}, :purl_canonical),
      cpes: package.cpes || [],
      coordinate_hash: EndpointInventoryPackageSet.coordinate_hash(package),
      package_set_hash: context.package_set_hash,
      previous_package_set_hash: Map.get(current || %{}, :package_set_hash),
      artifact_hash: context.artifact_hash,
      metadata: package_event_metadata(event, context),
      inserted_at: context.now
    }
  end

  defp changed_scan_time(context) do
    context.last_successful_scan_at || context.last_scan_at || context.now
  end

  defp scan_history_metadata(current, context) do
    context.metadata
    |> Map.merge(%{
      "previous_scan_ref" => encode_uuid(Map.get(current || %{}, :id)),
      "previous_scan_id" => Map.get(current || %{}, :scan_id),
      "source" => "endpoint_inventory_history"
    })
    |> Payload.compact_map()
  end

  defp package_event_metadata(event, context) do
    event
    |> Map.take([:event_type])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{
      "source" => "endpoint_inventory_diff",
      "package_set_hash" => context.package_set_hash,
      "artifact_hash" => context.artifact_hash
    })
    |> Payload.compact_map()
  end

  defp apply_current_count_changes([], _context), do: :ok

  defp apply_current_count_changes(package_events, context) do
    package_events
    |> Enum.flat_map(&package_count_changes/1)
    |> Enum.each(fn {package, delta, event} ->
      event_id = package_count_event_id(context, event, package, delta)
      host_count = upsert_current_package_count(package, delta, context)
      insert_package_count_history(package, delta, host_count, event_id, context)

      package
      |> Map.get(:cpes, [])
      |> Enum.uniq()
      |> Enum.reject(&Payload.blank?/1)
      |> Enum.each(fn cpe ->
        cpe_host_count = upsert_current_cpe_count(cpe, delta, context)
        insert_cpe_count_history(cpe, delta, cpe_host_count, event_id, context)
      end)
    end)

    :ok
  end

  defp package_count_changes(%{event_type: @package_event_added, package: package} = event) do
    [{package, 1, event}]
  end

  defp package_count_changes(
         %{event_type: @package_event_removed, previous_package: package} = event
       ) do
    [{package, -1, event}]
  end

  defp package_count_changes(
         %{
           event_type: @package_event_version_changed,
           previous_package: previous_package,
           package: package
         } = event
       ) do
    [{previous_package, -1, event}, {package, 1, event}]
  end

  defp upsert_current_package_count(package, delta, context) do
    coordinate_hash = EndpointInventoryPackageSet.coordinate_hash(package)

    %{rows: [[host_count]]} =
      Repo.query!(
        """
        INSERT INTO platform.endpoint_inventory_current_package_counts (
          coordinate_hash,
          package_manager,
          ecosystem,
          name,
          version,
          architecture,
          purl_canonical,
          cpes,
          host_count,
          first_seen_at,
          last_seen_at,
          updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, GREATEST($9::integer, 0), $10, $10, $10)
        ON CONFLICT (coordinate_hash) DO UPDATE SET
          package_manager = EXCLUDED.package_manager,
          ecosystem = EXCLUDED.ecosystem,
          name = EXCLUDED.name,
          version = EXCLUDED.version,
          architecture = EXCLUDED.architecture,
          purl_canonical = EXCLUDED.purl_canonical,
          cpes = EXCLUDED.cpes,
          host_count = GREATEST(0, endpoint_inventory_current_package_counts.host_count + $9::integer),
          last_seen_at = $10,
          updated_at = $10
        RETURNING host_count
        """,
        [
          coordinate_hash,
          package.package_manager,
          package.ecosystem,
          package.name,
          package.version,
          package.architecture,
          package.purl_canonical,
          package.cpes || [],
          delta,
          context.now
        ]
      )

    host_count
  end

  defp insert_package_count_history(package, delta, host_count, event_id, context) do
    Repo.insert_all(
      "endpoint_inventory_package_count_history",
      [
        %{
          scan_time: changed_scan_time(context),
          event_id: event_id,
          coordinate_hash: EndpointInventoryPackageSet.coordinate_hash(package),
          package_manager: package.package_manager,
          ecosystem: package.ecosystem,
          name: package.name,
          version: package.version,
          architecture: package.architecture,
          purl_canonical: package.purl_canonical,
          cpes: package.cpes || [],
          host_count: host_count,
          count_delta: delta,
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          scan_id: context.scan_id,
          inserted_at: context.now
        }
      ],
      prefix: "platform"
    )
  end

  defp upsert_current_cpe_count(cpe, delta, context) do
    %{rows: [[host_count]]} =
      Repo.query!(
        """
        INSERT INTO platform.endpoint_inventory_current_cpe_counts (
          cpe,
          host_count,
          first_seen_at,
          last_seen_at,
          updated_at
        )
        VALUES ($1, GREATEST($2::integer, 0), $3, $3, $3)
        ON CONFLICT (cpe) DO UPDATE SET
          host_count = GREATEST(0, endpoint_inventory_current_cpe_counts.host_count + $2::integer),
          last_seen_at = $3,
          updated_at = $3
        RETURNING host_count
        """,
        [cpe, delta, context.now]
      )

    host_count
  end

  defp insert_cpe_count_history(cpe, delta, host_count, event_id, context) do
    Repo.insert_all(
      "endpoint_inventory_cpe_count_history",
      [
        %{
          scan_time: changed_scan_time(context),
          event_id: event_id,
          cpe: cpe,
          host_count: host_count,
          count_delta: delta,
          agent_id: context.agent_id,
          device_uid: context.device_uid,
          scan_id: context.scan_id,
          inserted_at: context.now
        }
      ],
      prefix: "platform"
    )
  end

  defp package_event_id(context, event_type, coordinate_hash) do
    "inventory:#{context.agent_id}:#{context.scan_id}:#{event_type}:#{coordinate_hash}"
  end

  defp package_count_event_id(context, event, package, delta) do
    delta_key = if delta > 0, do: "inc", else: "dec"
    coordinate_hash = EndpointInventoryPackageSet.coordinate_hash(package)

    "inventory-count:#{context.agent_id}:#{context.scan_id}:#{event.event_type}:#{delta_key}:#{coordinate_hash}"
  end

  defp encode_uuid(uuid) when is_binary(uuid) and byte_size(uuid) == 16 do
    case Ecto.UUID.load(uuid) do
      {:ok, encoded} -> encoded
      :error -> Base.encode16(uuid, case: :lower)
    end
  end

  defp encode_uuid(uuid), do: uuid
end
