defmodule ServiceRadar.Observability.MtrCausalSignalEmitter do
  @moduledoc """
  Emits normalized MTR-derived causal signal envelopes with topology join keys.
  """

  alias ServiceRadar.Observability.CausalPubSub
  alias ServiceRadar.Repo

  require Logger

  @schema_version "1.0"
  @signal_type "mtr"

  @spec emit(map(), map(), [map()]) :: :ok | {:error, term()}
  def emit(consensus_result, context, outcomes)
      when is_map(consensus_result) and is_map(context) and is_list(outcomes) do
    event_identity = Ecto.UUID.generate()
    envelope = build_normalized_envelope(consensus_result, context, outcomes, event_identity)
    row = build_ocsf_event_row(envelope)

    case Repo.insert_all("ocsf_events", [row], on_conflict: :nothing, returning: false) do
      {1, _} ->
        CausalPubSub.broadcast_ingest(%{
          count: 1,
          signal_type: @signal_type,
          classification: envelope["event_type"],
          incident_correlation_id:
            context["incident_correlation_id"] || context[:incident_correlation_id]
        })

        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("MTR causal signal emission failed", reason: inspect(error))
      {:error, error}
  end

  @spec build_normalized_envelope(map(), map(), [map()], String.t()) :: map()
  def build_normalized_envelope(consensus_result, context, outcomes, event_identity)
      when is_map(consensus_result) and is_map(context) and is_list(outcomes) and
             is_binary(event_identity) do
    classification = consensus_result[:classification] || :insufficient_evidence
    confidence = to_float(consensus_result[:confidence], 0.0)
    evidence = consensus_result[:evidence] || %{}
    severity_id = severity_id_for(classification, confidence)
    event_time = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    target_device_uid = get(context, [:target_device_uid, "target_device_uid"])
    target_ip = get(context, [:target_ip, "target_ip"])
    partition_id = get(context, [:partition_id, "partition_id"])
    incident_correlation_id = get(context, [:incident_correlation_id, "incident_correlation_id"])
    source_agent_ids = source_agent_ids(context, outcomes)

    %{
      "schema_version" => @schema_version,
      "signal_type" => @signal_type,
      "event_type" => Atom.to_string(classification),
      "severity_id" => severity_id,
      "source" => %{
        "subject" => "internal.causal.mtr",
        "collector" => "serviceradar_core",
        "system" => "serviceradar"
      },
      "source_identity" => %{
        "agent_ids" => source_agent_ids
      },
      "event_identity" => event_identity,
      "event_time" => event_time,
      "routing_correlation" => %{
        "incident_correlation_id" => incident_correlation_id,
        "target_device_uid" => target_device_uid,
        "target_ip" => target_ip,
        "partition_id" => partition_id,
        "topology_keys" => %{
          "target_device_uid" => target_device_uid,
          "target_ip" => target_ip,
          "partition_id" => partition_id
        }
      },
      "grouped_contexts" => [],
      "signal_domains" => ["network_path", "topology"],
      "primary_domain" => "network_path",
      "explainability" => %{
        "classification" => Atom.to_string(classification),
        "confidence" => confidence,
        "consensus_evidence" => evidence,
        "source_agent_ids" => source_agent_ids,
        "incident_correlation_id" => incident_correlation_id
      },
      "guardrails" => %{
        "outcome_count" => length(outcomes)
      }
    }
  end

  @spec build_ocsf_event_row(map()) :: map()
  def build_ocsf_event_row(envelope) when is_map(envelope) do
    severity_id = envelope["severity_id"] || 1
    message = "#{envelope["event_type"]} mtr causal signal"
    correlation = envelope["routing_correlation"] || %{}

    %{
      id: Ecto.UUID.dump!(envelope["event_identity"]),
      time: envelope["event_time"],
      class_uid: 1008,
      category_uid: 1,
      type_uid: 1_008_003,
      activity_id: 1,
      activity_name: "Causal Signal",
      severity_id: severity_id,
      severity: severity_name(severity_id),
      message: message,
      status_id: nil,
      status: nil,
      status_code: nil,
      status_detail: nil,
      metadata: envelope,
      observables: [],
      trace_id: nil,
      span_id: nil,
      actor: %{},
      device: %{
        "uid" => correlation["target_device_uid"],
        "ip" => correlation["target_ip"]
      },
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: "internal.causal.mtr",
      log_provider: "serviceradar",
      log_level: severity_log_level(severity_id),
      log_version: envelope["schema_version"] || @schema_version,
      unmapped: %{"signal_type" => @signal_type},
      raw_data: Jason.encode!(envelope),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp source_agent_ids(context, outcomes) do
    context_ids =
      get(context, [:source_agent_ids, "source_agent_ids"])
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    outcome_ids =
      outcomes
      |> Enum.map(fn outcome -> get(outcome, [:agent_id, "agent_id"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    (context_ids ++ outcome_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp severity_id_for(:target_outage, _confidence), do: 6
  defp severity_id_for(:path_scoped_issue, confidence) when confidence >= 0.75, do: 5
  defp severity_id_for(:path_scoped_issue, _confidence), do: 4
  defp severity_id_for(:degraded_path, confidence) when confidence >= 0.75, do: 4
  defp severity_id_for(:degraded_path, _confidence), do: 3
  defp severity_id_for(:healthy, _confidence), do: 1
  defp severity_id_for(_, _), do: 2

  defp severity_name(id) when id >= 6, do: "critical"
  defp severity_name(5), do: "high"
  defp severity_name(4), do: "medium"
  defp severity_name(3), do: "low"
  defp severity_name(2), do: "informational"
  defp severity_name(_), do: "informational"

  defp severity_log_level(id) when id >= 6, do: "error"
  defp severity_log_level(id) when id >= 4, do: "warning"
  defp severity_log_level(_), do: "info"

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value / 1.0
  defp to_float(_value, default), do: default

  defp get(map, keys) when is_map(map) and is_list(keys),
    do: Enum.find_value(keys, fn key -> Map.get(map, key) end)

  defp get(_, _), do: nil
end
