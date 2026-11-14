defmodule ServiceRadar.Edge.Projectors.WasmPluginResult do
  @moduledoc """
  Projects `serviceradar.plugin_results.batch` edge records into
  `ServiceRadar.Observability.PluginResultIngestor`.

  Each typed result item is turned back into the `serviceradar.plugin_result.v1`
  payload map and gateway status, and ingested via
  `PluginResultIngestor.ingest_durable/3` under the four-way outcome contract
  (`applied`, `settled`, `refused`, `retryable`).

  Before projecting, the record's standing grant is re-checked
  (`OutputGrants.check_current/5`); a grant that is not current refuses the
  record. Partition `NotFound` refuses the record on delivery 1
  (`:plugin_result_batch_partition_not_found`), whereas transient partition or
  agent capability lookup errors return `{:error, ...}` so JetStream redelivers
  with backoff rather than coercing DB errors into empty capabilities.

  Out-of-line staged artifacts (such as staged running-config objects) are
  deleted only in `committed/3` after `edge_delivery_slots` and `event_ledger`
  commit for an `applied` or `settled` primary delivery, preserving artifacts
  intact across retries and dead-letter replay.
  """

  @behaviour ServiceRadar.Edge.Projector

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Compression
  alias ServiceRadar.Edge.OutputGrants
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.WasmPluginResultBatchV1
  alias Serviceradar.Edge.V1.WasmPluginResultItemV1
  alias ServiceRadar.Edge.WireDecode
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.NetworkConfig.PluginIngestor
  alias ServiceRadar.Observability.PluginResultIngestor

  require Logger

  @doc """
  Decodes and validates the batch of a plugin-results record: no source
  authorization, host-stamped assignment provenance, at least one result,
  one projected row per result, and per result a known status and a summary.
  """
  @impl true
  def decode(
        %EdgeRecordV1{
          source_authorization: nil,
          payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
        } = record
      ) do
    with {:ok, body} <- Compression.inner_payload(record),
         {:ok, %WasmPluginResultBatchV1{} = batch} <- WireDecode.decode_plugin_result_batch(body),
         :ok <- check(batch.results != [], :plugin_result_batch_empty),
         :ok <-
           check(
             length(batch.results) == record.projected_row_count,
             :plugin_result_batch_row_count
           ),
         {:ok, provenance} <- provenance(batch),
         :ok <- check_results(batch.results) do
      {:ok, {batch, provenance}}
    end
  end

  def decode(%EdgeRecordV1{source_authorization: nil}), do: {:error, :unsupported_payload_family}
  def decode(%EdgeRecordV1{}), do: {:error, :plugin_result_batch_source_authorization}

  @doc """
  Ingests every result of a fresh primary record after checking its grant
  is still current. Propagates `:ok`, `{:settled, reason}`, `{:refused, reason}`,
  and `{:error, reason}` according to the lattice `retryable > refused > applied > settled`.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, {%WasmPluginResultBatchV1{} = batch, provenance}, opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id
    check_grant_fn = Keyword.get(opts, :check_grant_fn, &OutputGrants.check_current/5)

    with :ok <-
           check_grant_fn.(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             Ecto.UUID.load!(record.network_scope_id),
             context.authority_epoch
           ),
         {:ok, partition} <- partition(record.network_scope_id, opts),
         {:ok, capabilities} <- delivery_capabilities(agent_id, opts) do
      ingest_results(batch, provenance, agent_id, partition, capabilities, opts)
    else
      {:error, :output_grant_not_current} -> {:refused, :output_grant_not_current}
      {:refused, _reason} = refused -> refused
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cleans up staged out-of-line artifacts after `edge_delivery_slots` and
  `event_ledger` commit for a primary delivery (`applied` or `settled`).
  """
  @impl true
  def committed(
        %EdgeRecordV1{} = record,
        {%WasmPluginResultBatchV1{} = batch, provenance},
        %{primary?: true} = context
      ) do
    agent_id = record.producer_context.origin_principal_id
    projector_opts = Map.get(context, :projector_opts, [])

    cleanup_fn =
      Keyword.get(
        projector_opts,
        :cleanup_artifacts_fn,
        &PluginIngestor.discard_artifacts/2
      )

    Enum.each(batch.results, fn item ->
      payload = result_payload(item)
      status = %{agent_id: agent_id, plugin_provenance: provenance}

      case cleanup_fn.(payload, status) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Staged plugin artifact cleanup after commit failed",
            agent_id: agent_id,
            assignment_id: provenance["assignment_id"],
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  def committed(_record, _body, _context), do: :ok

  defp ingest_results(batch, provenance, agent_id, partition, capabilities, opts) do
    ingestor_opts =
      opts
      |> Keyword.get(:ingestor_opts, [])
      |> Keyword.put(:defer_artifact_cleanup, true)

    batch.results
    |> Enum.reduce_while({:initial, nil}, fn item, {acc_state, acc_reason} ->
      payload = result_payload(item)
      status = result_status(item, provenance, agent_id, partition, capabilities)

      case PluginResultIngestor.ingest_durable(payload, status, ingestor_opts) do
        :ok ->
          {:cont, if(acc_state == :refused, do: {acc_state, acc_reason}, else: {:applied, nil})}

        {:settled, settled_reason} ->
          case acc_state do
            :initial -> {:cont, {:settled, settled_reason}}
            _other -> {:cont, {acc_state, acc_reason}}
          end

        {:refused, refused_reason} ->
          case acc_state do
            :refused -> {:cont, {acc_state, acc_reason}}
            _other -> {:cont, {:refused, refused_reason}}
          end

        {:error, reason} ->
          {:halt, {:error, {:plugin_result_ingest_failed, reason}}}
      end
    end)
    |> case do
      {:applied, _} -> :ok
      {:initial, _} -> :ok
      {:settled, settled_reason} -> {:settled, settled_reason}
      {:refused, refused_reason} -> {:refused, refused_reason}
      {:error, _} = error -> error
    end
  end

  # The status the gateway status push carried for one result, minus the
  # connecting gateway's id. `plugin_provenance` is the host stamp the
  # ingestor keys its per-assignment service identity on; dropping it would
  # silently merge coexisting assignments under the bare package name.
  # `delivery_capabilities` replaces the per-chunk capabilities the gateway
  # stamped from the agent's authenticated session.
  defp result_status(
         %WasmPluginResultItemV1{} = item,
         provenance,
         agent_id,
         partition,
         capabilities
       ) do
    observed_at = observed_at_iso(item)

    %{
      agent_id: agent_id,
      service_name: service_name(item, provenance),
      service_type: "plugin",
      partition: partition,
      source: "plugin-result",
      available: item.status in [:PLUGIN_RESULT_STATUS_OK, :PLUGIN_RESULT_STATUS_WARNING],
      timestamp: observed_at,
      agent_timestamp: observed_at,
      plugin_provenance: provenance,
      delivery_capabilities: capabilities
    }
  end

  defp delivery_capabilities(agent_id, opts) do
    lookup_fn =
      Keyword.get(opts, :agent_lookup_fn, fn id ->
        Agent.get_by_uid(id, actor: SystemActor.system(:wasm_plugin_result_projector))
      end)

    case lookup_fn.(agent_id) do
      {:ok, %Agent{capabilities: capabilities}} when is_list(capabilities) ->
        {:ok, capabilities}

      {:ok, %Agent{}} ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:error, reason} ->
        if ash_not_found?(reason) do
          {:ok, []}
        else
          {:error, {:plugin_result_agent_lookup_failed, reason}}
        end
    end
  end

  defp service_name(%WasmPluginResultItemV1{service_name: name}, _provenance)
       when is_binary(name) and name != "",
       do: name

  defp service_name(_item, %{"plugin_id" => plugin_id})
       when is_binary(plugin_id) and plugin_id != "", do: plugin_id

  defp service_name(_item, %{"assignment_id" => assignment_id}), do: assignment_id

  defp observed_at_iso(%WasmPluginResultItemV1{observed_at_unix_nano: nanos})
       when is_integer(nanos) and nanos > 0 do
    nanos
    |> DateTime.from_unix!(:nanosecond)
    |> DateTime.to_iso8601()
  end

  defp observed_at_iso(_item), do: nil

  defp partition(network_scope_id, opts) do
    lookup_fn =
      Keyword.get(opts, :partition_lookup_fn, fn id ->
        Partition.get_by_id(id, actor: SystemActor.system(:wasm_plugin_result_projector))
      end)

    case Ecto.UUID.load(network_scope_id) do
      {:ok, scope_id} ->
        case lookup_fn.(scope_id) do
          {:ok, %Partition{slug: slug}} when is_binary(slug) and slug != "" ->
            {:ok, slug}

          {:ok, _missing} ->
            {:refused, :plugin_result_batch_partition_not_found}

          {:error, reason} ->
            if ash_not_found?(reason) do
              {:refused, :plugin_result_batch_partition_not_found}
            else
              {:error, {:plugin_result_partition_lookup_failed, reason}}
            end
        end

      :error ->
        {:refused, :plugin_result_batch_partition_not_found}
    end
  end

  defp ash_not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp ash_not_found?(:not_found), do: true

  defp ash_not_found?(%{errors: errors}) when is_list(errors) do
    errors != [] and Enum.all?(errors, &ash_not_found?/1)
  end

  defp ash_not_found?(_other), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp provenance(%WasmPluginResultBatchV1{provenance: nil}),
    do: {:error, :plugin_result_batch_no_provenance}

  defp provenance(%WasmPluginResultBatchV1{provenance: provenance}) do
    normalized =
      %{
        "assignment_id" => provenance.assignment_id,
        "plugin_id" => provenance.plugin_id,
        "plugin_package_id" => provenance.plugin_package_id,
        "plugin_version" => provenance.plugin_version,
        "content_hash" => provenance.content_hash
      }
      |> Enum.reject(fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end)
      |> Map.new()

    if is_binary(normalized["assignment_id"]) do
      {:ok, normalized}
    else
      {:error, :plugin_result_batch_no_provenance}
    end
  end

  defp check_results(results) do
    Enum.reduce_while(results, :ok, fn
      %WasmPluginResultItemV1{status: :PLUGIN_RESULT_STATUS_UNSPECIFIED}, :ok ->
        {:halt, {:error, :plugin_result_no_status}}

      %WasmPluginResultItemV1{summary: summary}, :ok ->
        if is_binary(summary) and String.trim(summary) != "" do
          {:cont, :ok}
        else
          {:halt, {:error, :plugin_result_no_summary}}
        end
    end)
  end

  # Rebuilds the serviceradar.plugin_result.v1 payload map the ingestor and
  # its registered handlers read. Typed sub-bodies that core stores or
  # correlates on ride back as their decoded JSON values. Schema'd bodies
  # that travel in `details` stay there verbatim; a top-level threat-intel
  # page goes back under `threat_intel`, the key its handler reads first.
  defp result_payload(%WasmPluginResultItemV1{} = item) do
    payload =
      put_present(
        %{
          "status" => status_label(item.status),
          "summary" => item.summary,
          "details" => item.details,
          "perfdata" => item.perfdata,
          "labels" => item.labels || %{},
          "observed_at" => observed_at_iso(item),
          "schema_version" => item.schema_version,
          "alert_hint" => item.alert_hint,
          "condition_id" => item.condition_id,
          "check_instance_id" => item.check_instance_id,
          "monitored_service_id" => item.monitored_service_id,
          "device_uid" => item.device_uid,
          "display" => Enum.map(item.display || [], &display_payload/1),
          "events" => Enum.map(item.events || [], &decode_json(&1.payload_json)),
          "device_discovery" => Enum.map(item.device_discovery || [], &discovery_payload/1),
          "advisory_feeds" => Enum.map(item.advisory_feeds || [], &advisory_payload/1)
        },
        "run_overrides_acknowledged",
        item.run_overrides_acknowledged
      )

    payload =
      case item.threat_intel_page do
        nil -> payload
        page -> Map.put(payload, "threat_intel", decode_json(page.payload_json))
      end

    Map.reject(payload, fn {_key, value} -> value in [nil, ""] end)
  end

  defp display_payload(widget) do
    Map.reject(
      %{
        "widget" => widget.widget,
        "label" => widget.label,
        "value" => widget.value,
        "tone" => widget.tone,
        "layout" => widget.layout,
        "data" => decode_json(widget.data_json)
      },
      fn {_key, value} -> value in [nil, ""] end
    )
  end

  defp discovery_payload(item) do
    Map.reject(
      %{
        "schema" => item.schema,
        "collection_id" => item.collection_id,
        "source" => item.source,
        "observed_at" => item.observed_at,
        "reference_hash" => item.reference_hash,
        "devices" => Enum.map(item.devices || [], &device_payload/1),
        "metadata" => decode_json(item.metadata_json)
      },
      fn {_key, value} -> value in [nil, ""] end
    )
  end

  defp device_payload(device) do
    payload = %{
      "device_id" => device.device_id,
      "hostname" => device.hostname,
      "ip" => device.ip,
      "mac" => device.mac,
      "serial" => device.serial,
      "vendor_name" => device.vendor_name,
      "model" => device.model,
      "type" => device.type,
      "role" => device.role,
      "status" => device.status,
      "labels" => device.labels || %{},
      "metadata" => decode_json(device.metadata_json)
    }

    payload =
      if device.has_is_available,
        do: Map.put(payload, "is_available", device.is_available),
        else: payload

    case_result =
      case device.location do
        nil ->
          payload

        location ->
          loc = %{"site_code" => location.site_code, "site_name" => location.site_name}

          loc =
            if location.has_latitude, do: Map.put(loc, "latitude", location.latitude), else: loc

          loc =
            if location.has_longitude,
              do: Map.put(loc, "longitude", location.longitude),
              else: loc

          Map.put(payload, "location", loc)
      end

    Map.reject(case_result, fn {_key, value} -> value in [nil, ""] end)
  end

  defp advisory_payload(batch) do
    Map.reject(
      %{
        "schema_version" => batch.schema_version,
        "producer_id" => batch.producer_id,
        "source" => decode_json(batch.source_json),
        "snapshot" => decode_json(batch.snapshot_json),
        "advisories" => Enum.map(batch.advisories_json || [], &decode_json/1),
        "metadata" => decode_json(batch.metadata_json)
      },
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp status_label(:PLUGIN_RESULT_STATUS_OK), do: "OK"
  defp status_label(:PLUGIN_RESULT_STATUS_WARNING), do: "WARNING"
  defp status_label(:PLUGIN_RESULT_STATUS_CRITICAL), do: "CRITICAL"
  defp status_label(_status), do: "UNKNOWN"

  defp put_present(payload, _key, value) when value in [nil, []], do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp decode_json(nil), do: nil
  defp decode_json(""), do: nil

  defp decode_json(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end
end
