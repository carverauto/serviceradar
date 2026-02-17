defmodule ServiceRadar.EventWriter.Processors.CausalSignals do
  @moduledoc """
  Processor for external causal signals (BMP and SIEM) consumed via JetStream.

  This processor normalizes external events into a common causal envelope and
  persists them in `ocsf_events` so downstream topology overlays can evaluate
  causality from a durable source.

  Expected subjects include:
  - `bmp.events.>`
  - `siem.events.>`
  - `signals.causal.>`
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Observability.CausalPubSub

  require Logger

  @schema_version "1.0"
  @max_grouped_contexts 32

  @impl true
  def table_name, do: "ocsf_events"

  @impl true
  def process_batch(messages) do
    rows =
      messages
      |> Enum.map(&parse_message/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      case ServiceRadar.Repo.insert_all(table_name(), rows,
             on_conflict: :nothing,
             returning: false
           ) do
        {count, _} ->
          CausalPubSub.broadcast_ingest(%{count: count})
          {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("Causal signals batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    with {:ok, payload} <- Jason.decode(data),
         {:ok, normalized} <- normalize_payload(payload, metadata, data) do
      build_ocsf_event_row(normalized, payload, data, metadata)
    else
      _ ->
        Logger.debug("Failed to parse causal signal payload", subject: metadata[:subject])
        nil
    end
  end

  defp normalize_payload(payload, metadata, raw_data) when is_map(payload) do
    subject = metadata[:subject] || ""
    signal_type = infer_signal_type(subject, payload)
    severity_id = normalize_severity(payload)
    grouped_contexts = grouped_contexts(payload)
    domains = signal_domains(payload, signal_type)
    {primary_domain, precedence_rank} = primary_domain(domains)
    truncated_contexts = Enum.take(grouped_contexts, @max_grouped_contexts)
    contexts_truncated = length(grouped_contexts) > length(truncated_contexts)

    event_time =
      payload["timestamp"] || payload["time"] || payload["event_time"] || metadata[:received_at]

    envelope = %{
      "schema_version" => @schema_version,
      "signal_type" => signal_type,
      "severity_id" => severity_id,
      "source" => normalize_source(payload, subject),
      "event_identity" => stable_event_identity(subject, payload, raw_data),
      "event_time" => normalize_time(event_time),
      "grouped_contexts" => truncated_contexts,
      "signal_domains" => domains,
      "primary_domain" => primary_domain,
      "explainability" => %{
        "source_signal_refs" => source_signal_refs(payload),
        "context_ids" => Enum.map(truncated_contexts, & &1["id"]),
        "primary_domain" => primary_domain,
        "precedence_rank" => precedence_rank
      },
      "guardrails" => %{
        "max_grouped_contexts" => @max_grouped_contexts,
        "contexts_truncated" => contexts_truncated,
        "input_context_count" => length(grouped_contexts),
        "applied_context_count" => length(truncated_contexts)
      }
    }

    {:ok, envelope}
  end

  defp normalize_payload(_, _, _), do: {:error, :invalid_payload}

  defp build_ocsf_event_row(normalized, payload, raw_data, metadata) do
    severity_id = normalized["severity_id"]
    signal_type = normalized["signal_type"]
    event_identity = normalized["event_identity"]

    %{
      id: Ecto.UUID.dump!(event_identity),
      time: normalized["event_time"],
      class_uid: 1008,
      category_uid: 1,
      type_uid: type_uid_for(signal_type),
      activity_id: 1,
      activity_name: "Causal Signal",
      severity_id: severity_id,
      severity: severity_name(severity_id),
      message: payload["message"] || payload["description"] || "#{signal_type} causal signal",
      status_id: nil,
      status: nil,
      status_code: nil,
      status_detail: nil,
      metadata: normalized,
      observables: [],
      trace_id: nil,
      span_id: nil,
      actor: %{},
      device: normalize_device(payload),
      src_endpoint: normalize_src_endpoint(payload),
      dst_endpoint: %{},
      log_name: metadata[:subject],
      log_provider: payload["provider"] || payload["source"] || "external",
      log_level: payload["level"],
      log_version: payload["version"] || @schema_version,
      unmapped: payload,
      raw_data: raw_data,
      created_at: DateTime.utc_now()
    }
  end

  defp infer_signal_type(subject, payload) do
    cond do
      is_binary(payload["signal_type"]) -> String.downcase(payload["signal_type"])
      String.starts_with?(subject, "bmp.events.") -> "bmp"
      String.starts_with?(subject, "siem.events.") -> "siem"
      true -> "unknown"
    end
  end

  defp normalize_source(payload, subject) do
    %{
      "subject" => subject,
      "collector" => payload["collector"] || payload["source_collector"],
      "system" => payload["source"] || payload["provider"] || "external"
    }
  end

  defp grouped_contexts(payload) when is_map(payload) do
    security_zones =
      payload
      |> list_or_scalar(["security_zones", "security_zone"])
      |> Enum.map(&build_context("security_zone", &1))

    bgp_prefix_groups =
      payload
      |> list_or_scalar(["bgp_prefix_groups", "bgp_prefix_group"])
      |> Enum.map(&build_context("bgp_prefix_group", &1))

    (security_zones ++ bgp_prefix_groups)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1["type"], &1["id"]})
  end

  defp grouped_contexts(_), do: []

  defp list_or_scalar(payload, [list_key, scalar_key]) do
    cond do
      is_list(payload[list_key]) ->
        payload[list_key]

      is_binary(payload[scalar_key]) ->
        [payload[scalar_key]]

      true ->
        []
    end
  end

  defp build_context(type, id) when is_binary(id) do
    normalized = String.trim(id)
    if normalized == "", do: nil, else: %{"type" => type, "id" => normalized}
  end

  defp build_context(_type, _id), do: nil

  defp signal_domains(payload, signal_type) do
    normalized =
      case payload["signal_domains"] do
        values when is_list(values) ->
          Enum.map(values, &normalize_domain/1)

        _ ->
          [normalize_domain(payload["signal_domain"] || signal_type)]
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized == [], do: ["unknown"], else: normalized
  end

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "security" -> "security"
      "routing" -> "routing"
      "health" -> "health"
      "bmp" -> "routing"
      "siem" -> "security"
      "unknown" -> "unknown"
      "" -> nil
      _ -> "unknown"
    end
  end

  defp normalize_domain(_), do: nil

  defp primary_domain(domains) when is_list(domains) do
    domains
    |> Enum.map(&{&1, domain_rank(&1)})
    |> Enum.max_by(fn {domain, rank} -> {rank, domain} end, fn -> {"unknown", 0} end)
  end

  defp primary_domain(_), do: {"unknown", 0}

  defp domain_rank("security"), do: 3
  defp domain_rank("routing"), do: 2
  defp domain_rank("health"), do: 1
  defp domain_rank(_), do: 0

  defp source_signal_refs(payload) when is_map(payload) do
    [
      payload["event_id"],
      payload["id"],
      payload["eventId"],
      payload["alert_id"],
      payload["bmp_message_id"],
      payload["message_id"]
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_signal_refs(_), do: []

  defp normalize_time(%DateTime{} = dt), do: dt

  defp normalize_time(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  rescue
    _ -> DateTime.utc_now()
  end

  defp normalize_severity(payload) do
    cond do
      is_integer(payload["severity_id"]) -> clamp_severity(payload["severity_id"])
      is_integer(payload["severity"]) -> clamp_severity(payload["severity"])
      is_binary(payload["severity"]) -> severity_from_string(payload["severity"])
      true -> 3
    end
  end

  defp clamp_severity(value) when value < 0, do: 0
  defp clamp_severity(value) when value > 6, do: 6
  defp clamp_severity(value), do: value

  @severity_map %{
    "unknown" => 0,
    "informational" => 1,
    "info" => 1,
    "low" => 2,
    "medium" => 3,
    "high" => 4,
    "critical" => 5,
    "fatal" => 6
  }

  defp severity_from_string(value) do
    Map.get(@severity_map, String.downcase(value), 3)
  end

  defp severity_name(0), do: "Unknown"
  defp severity_name(1), do: "Informational"
  defp severity_name(2), do: "Low"
  defp severity_name(3), do: "Medium"
  defp severity_name(4), do: "High"
  defp severity_name(5), do: "Critical"
  defp severity_name(6), do: "Fatal"
  defp severity_name(_), do: "Unknown"

  defp type_uid_for("bmp"), do: 100_811
  defp type_uid_for("siem"), do: 100_812
  defp type_uid_for(_), do: 100_810

  defp normalize_device(payload) do
    device_id = payload["device_id"] || payload["deviceId"] || payload["router_id"]

    if is_binary(device_id) and device_id != "" do
      %{"uid" => device_id}
    else
      %{}
    end
  end

  defp normalize_src_endpoint(payload) do
    ip = payload["peer_ip"] || payload["src_ip"] || payload["source_ip"]

    if is_binary(ip) and ip != "" do
      %{"ip" => ip}
    else
      %{}
    end
  end

  defp stable_event_identity(subject, payload, raw_data) do
    source_id =
      payload["event_id"] ||
        payload["id"] ||
        payload["eventId"] ||
        payload["alert_id"] ||
        payload["bmp_message_id"] ||
        payload["message_id"]

    stable_key =
      if is_binary(source_id) and source_id != "" do
        "#{subject}:#{source_id}"
      else
        hash = Base.encode16(:crypto.hash(:sha256, raw_data), case: :lower)
        "#{subject}:#{hash}"
      end

    deterministic_uuid(stable_key)
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    # Set version 4 and variant 10xx for UUID compliance.
    versioned_a3 = Bitwise.band(a3, 0x0FFF) |> Bitwise.bor(0x4000)
    versioned_a4 = Bitwise.band(a4, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a1, a2, versioned_a3, versioned_a4, a5]
    )
    |> IO.iodata_to_binary()
  end
end
