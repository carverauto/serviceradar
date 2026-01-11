defmodule ServiceRadar.EventWriter.Processors.Events do
  @moduledoc """
  Processor for OCSF Event Log Activity payloads.

  Parses JSON events from NATS and inserts them into the `ocsf_events`
  hypertable using the OCSF Event Log Activity schema (class_uid: 1008).
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.TenantContext
  alias ServiceRadar.Observability.StatefulAlertEngine

  require Logger

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("OCSF events batch missing tenant schema context")
      {:error, :missing_tenant_schema}
    else
      rows =
        messages
        |> Enum.map(&parse_message/1)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(rows) do
        {:ok, 0}
      else
        case ServiceRadar.Repo.insert_all(table_name(), rows,
               prefix: schema,
               on_conflict: :nothing,
               returning: false
             ) do
          {count, _} ->
            maybe_evaluate_stateful_rules(rows, schema)
            {:ok, count}
        end
      end
    end
  rescue
    e ->
      Logger.error("OCSF events batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    tenant_id = TenantContext.resolve_tenant_id(message)

    if is_nil(tenant_id) do
      Logger.error("OCSF event missing tenant_id", subject: metadata[:subject])
      nil
    else
      case Jason.decode(data) do
        {:ok, json} ->
          parse_event(json, metadata, data, tenant_id)

        {:error, _} ->
          Logger.debug("Failed to parse events message as JSON")
          nil
      end
    end
  end

  # Private functions

  defp parse_event(json, metadata, raw_data, tenant_id) when is_map(json) do
    with {:ok, id} <- fetch_required_string(json, "id"),
         {:ok, class_uid} <- fetch_required_int(json, "class_uid"),
         {:ok, category_uid} <- fetch_required_int(json, "category_uid"),
         {:ok, type_uid} <- fetch_required_int(json, "type_uid"),
         {:ok, activity_id} <- fetch_required_int(json, "activity_id") do
      severity_id = parse_int(json["severity_id"]) || 1
      severity = parse_string(json["severity"]) || severity_name(severity_id)

      %{
        id: id,
        time: FieldParser.parse_timestamp(json["time"]),
        class_uid: class_uid,
        category_uid: category_uid,
        type_uid: type_uid,
        activity_id: activity_id,
        activity_name: parse_string(json["activity_name"]),
        severity_id: severity_id,
        severity: severity,
        message: parse_string(json["message"]),
        status_id: parse_int(json["status_id"]),
        status: parse_string(json["status"]),
        status_code: parse_string(json["status_code"]),
        status_detail: parse_string(json["status_detail"]),
        metadata: FieldParser.encode_jsonb(json["metadata"]) || %{},
        observables: FieldParser.encode_jsonb(json["observables"]) || [],
        trace_id: FieldParser.get_field(json, "trace_id", "traceId"),
        span_id: FieldParser.get_field(json, "span_id", "spanId"),
        actor: FieldParser.encode_jsonb(json["actor"]) || %{},
        device: FieldParser.encode_jsonb(json["device"]) || %{},
        src_endpoint: FieldParser.encode_jsonb(json["src_endpoint"]) || %{},
        dst_endpoint: FieldParser.encode_jsonb(json["dst_endpoint"]) || %{},
        log_name: parse_string(json["log_name"]) || metadata[:subject],
        log_provider: parse_string(json["log_provider"]),
        log_level: parse_string(json["log_level"]),
        log_version: parse_string(json["log_version"]),
        unmapped: FieldParser.encode_jsonb(json["unmapped"]) || %{},
        raw_data: parse_string(json["raw_data"]) || raw_data,
        tenant_id: tenant_id,
        created_at: DateTime.utc_now()
      }
    else
      {:error, reason} ->
        Logger.debug("Invalid OCSF event payload: #{inspect(reason)}",
          subject: metadata[:subject]
        )

        nil
    end
  end

  defp parse_event(_json, _metadata, _raw_data, _tenant_id), do: nil
  defp fetch_required_string(json, key) do
    case parse_string(json[key]) do
      nil -> {:error, {:missing, key}}
      "" -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp fetch_required_int(json, key) do
    case parse_int(json[key]) do
      nil -> {:error, {:missing, key}}
      0 -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_float(value), do: trunc(value)
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp parse_int(_), do: nil

  defp parse_string(value) when is_binary(value), do: value
  defp parse_string(_), do: nil

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp maybe_evaluate_stateful_rules([], _schema), do: :ok

  defp maybe_evaluate_stateful_rules(rows, schema) do
    tenant_id =
      case rows do
        [%{tenant_id: tenant_id} | _] -> tenant_id
        _ -> TenantContext.current_tenant_id()
      end

    if is_nil(tenant_id) do
      Logger.warning("Skipping stateful alert evaluation; missing tenant_id")
      :ok
    else
      case StatefulAlertEngine.evaluate_events(rows, tenant_id, schema) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("Stateful alert evaluation failed: #{inspect(reason)}")
          :ok
      end
    end
  end

end
