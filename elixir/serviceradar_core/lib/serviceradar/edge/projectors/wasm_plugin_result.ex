defmodule ServiceRadar.Edge.Projectors.WasmPluginResult do
  @moduledoc """
  Projects `serviceradar.plugin_results.batch` edge records into
  `ServiceRadar.Observability.PluginResultIngestor`, the destination Wasm
  plugin results have today.

  Each typed result item is turned back into the
  `serviceradar.plugin_result.v1` payload map and gateway status the legacy
  status push delivered, and ingested one result at a time, so the status
  rows, the registered platform handlers, and their redelivery semantics are
  unchanged. The batch provenance is host-stamped by the agent from its own
  assignment record; it rides the status as `plugin_provenance`, which is
  what keys the ingestor's per-assignment service identity
  (`PluginServiceIdentity`: the primary assignment keeps the bare package
  name, a coexisting assignment is `name#<assignment_id>`). A batch without
  that provenance is refused at decode, never ingested under a shared bare
  name.

  Before projecting, the record's standing grant is re-checked
  (`OutputGrants.check_current/5`); a grant that is not current refuses the
  record. An ingest error is an error, so the record is redelivered; the
  ingestor's own redelivery handling keeps a replay from running handlers
  twice for a committed result. The one identity the durable path cannot
  carry is the connecting gateway's id, which projected statuses leave unset
  rather than guessing.

  `delivery_capabilities` (which handlers such as the Proxmox source-scope
  resolver gate on) come from the authenticated agent's recorded capability
  list, read once per batch for the record's verified origin principal, never
  from the record payload. An agent with no record projects an empty list, so
  a capability-gated handler refuses the result.
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
  is still current. The first ingest error stops the batch so the record is
  redelivered; results already ingested are recognized by the ingestor's
  redelivery handling.
  """
  @impl true
  def publish(%EdgeRecordV1{} = record, {%WasmPluginResultBatchV1{} = batch, provenance}, _opts) do
    context = record.producer_context
    agent_id = context.origin_principal_id

    with :ok <-
           OutputGrants.check_current(
             Ecto.UUID.load!(context.producer_assignment_id),
             agent_id,
             record.output_contract.contract_id,
             Ecto.UUID.load!(record.network_scope_id),
             context.authority_epoch
           ),
         {:ok, partition} <- partition(record.network_scope_id),
         :ok <-
           ingest_results(batch, provenance, agent_id, partition, delivery_capabilities(agent_id)) do
      :ok
    else
      {:error, :output_grant_not_current} -> {:refused, :output_grant_not_current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest_results(batch, provenance, agent_id, partition, capabilities) do
    Enum.reduce_while(batch.results, :ok, fn item, :ok ->
      payload = result_payload(item)
      status = result_status(item, provenance, agent_id, partition, capabilities)

      case PluginResultIngestor.ingest(payload, status) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:plugin_result_ingest_failed, reason}}}
      end
    end)
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

  defp delivery_capabilities(agent_id) do
    case Agent.get_by_uid(agent_id, actor: SystemActor.system(:wasm_plugin_result_projector)) do
      {:ok, %Agent{capabilities: capabilities}} when is_list(capabilities) -> capabilities
      _ -> []
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

  defp partition(network_scope_id) do
    with {:ok, scope_id} <- Ecto.UUID.load(network_scope_id),
         {:ok, partition} <-
           Partition.get_by_id(scope_id, actor: SystemActor.system(:wasm_plugin_result_projector)) do
      {:ok, partition.slug}
    else
      _ -> {:error, :plugin_result_batch_partition}
    end
  end

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
