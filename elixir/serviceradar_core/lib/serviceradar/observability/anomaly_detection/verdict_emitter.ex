defmodule ServiceRadar.Observability.AnomalyDetection.VerdictEmitter do
  @moduledoc """
  Emits confirmed anomaly verdicts through the causal prediction spine.
  """

  alias ServiceRadar.NATS.Connection

  @subject_root "signals.causal.predictions"
  @event_type "anomaly"
  @provider "anomaly_detection"

  @spec emit(map(), map(), keyword()) :: :ok | {:error, term()}
  def emit(sample, verdict, opts \\ []) when is_map(sample) and is_map(verdict) do
    subject = subject(sample)
    payload = payload(sample, verdict, subject)
    publish_opts = Keyword.get(opts, :publish_opts, [])
    publisher = Keyword.get(opts, :publisher, &Connection.publish/3)

    publisher.(subject, Jason.encode!(payload), publish_opts)
  end

  @spec payload(map(), map()) :: map()
  def payload(sample, verdict) when is_map(sample) and is_map(verdict),
    do: payload(sample, verdict, subject(sample))

  @spec payload(map(), map(), String.t()) :: map()
  def payload(sample, verdict, subject)
      when is_map(sample) and is_map(verdict) and is_binary(subject) do
    device_uid = device_uid(sample)
    observed_at = observed_at(sample)
    series_key = string_value(value(sample, :series_key))
    metric_class = string_value(value(sample, :metric_class))

    %{
      "event_id" => event_id(sample, verdict),
      "signal_type" => "causal",
      "event_type" => @event_type,
      "status" => status(verdict),
      "finding_type" => "detection",
      "class_uid" => 2004,
      "signal_domain" => "health",
      "signal_domains" => ["health"],
      "timestamp" => iso8601(observed_at),
      "severity_id" => severity_id(verdict),
      "provider" => @provider,
      "source" => "serviceradar",
      "collector" => "anomaly_detection_pipeline",
      "device_id" => device_uid,
      "device_uid" => device_uid,
      "message" => message(sample, verdict),
      "finding_info" => finding_info(sample, verdict, device_uid, series_key, metric_class),
      "anomaly" => anomaly_payload(sample, verdict, observed_at),
      "explainability" => %{
        "classification" => @event_type,
        "reason" => string_value(value(verdict, :reason)) || "anomaly detected",
        "severity_score" => severity_score(verdict),
        "state" => string_value(value(verdict, :state)),
        "signals" => value(verdict, :signals) || []
      },
      "source_identity" => %{
        "entity_uid" => device_uid,
        "series_key" => series_key,
        "metric_class" => metric_class
      },
      "routing_correlation" => %{
        "record_id" => series_key,
        "topology_keys" =>
          [device_uid, series_key]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
      },
      "source_subject" => subject
    }
  end

  @spec subject(map()) :: String.t()
  def subject(sample) when is_map(sample) do
    "#{@subject_root}.#{subject_token(value(sample, :series_key) || @event_type)}"
  end

  @spec event_id(map(), map()) :: String.t()
  def event_id(sample, verdict) when is_map(sample) and is_map(verdict) do
    Enum.map_join(
      [
        @event_type,
        value(sample, :event_id),
        value(sample, :series_key),
        value(sample, :observed_at_unix_nano),
        value(verdict, :state)
      ],
      ":",
      &string_value/1
    )
  end

  defp anomaly_payload(sample, verdict, observed_at) do
    metadata = value(sample, :metadata) || %{}

    %{
      "series_key" => string_value(value(sample, :series_key)),
      "event_id" => string_value(value(sample, :event_id)),
      "order_key" => encode_order_key(value(sample, :order_key)),
      "subject" => string_value(value(sample, :subject)),
      "metric_class" => string_value(value(sample, :metric_class)),
      "observed_at" => iso8601(observed_at),
      "observed_at_unix_nano" => value(sample, :observed_at_unix_nano),
      "value" => value(sample, :value),
      "state" => string_value(value(verdict, :state)),
      "reason" => string_value(value(verdict, :reason)),
      "score" => value(verdict, :score),
      "baseline_count" => value(verdict, :baseline_count),
      "sample_value" => value(verdict, :sample_value),
      "signals" => value(verdict, :signals) || [],
      "metadata" => metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp message(sample, verdict) do
    series_key = string_value(value(sample, :series_key)) || "series"
    metric_class = string_value(value(sample, :metric_class)) || "metric"
    state = string_value(value(verdict, :state)) || "anomaly"
    reason = string_value(value(verdict, :reason)) || "threshold breached"

    "Anomaly detected: #{metric_class} #{series_key} entered #{state}: #{reason}"
  end

  defp status(verdict) do
    cond do
      value(verdict, :suppressed) == true ->
        "suppressed"

      value(verdict, :anomalous) == true ->
        "open"

      value(verdict, :state) in ["normal", "ok", "healthy", "closed", "resolved", "inactive"] ->
        "inactive"

      true ->
        "open"
    end
  end

  defp finding_info(sample, verdict, device_uid, series_key, metric_class) do
    uid = finding_uid(device_uid, series_key, metric_class)

    %{
      "uid" => uid,
      "group_uid" => uid,
      "title" => "Anomaly detection: #{metric_class || "metric"} #{series_key || "series"}",
      "type" => "ServiceRadar Anomaly",
      "type_id" => 99,
      "source" => @provider,
      "dimensions" =>
        %{
          "class_uid" => 2004,
          "source" => @provider,
          "device_uid" => device_uid,
          "series_key" => series_key,
          "metric_class" => metric_class,
          "state" => string_value(value(verdict, :state)),
          "subject" => string_value(value(sample, :subject))
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp finding_uid(device_uid, series_key, metric_class) do
    stable_key =
      Enum.map_join(
        [@event_type, 2004, @provider, device_uid, series_key, metric_class],
        ":",
        &string_value/1
      )

    deterministic_uuid("anomaly:finding:#{stable_key}")
  end

  defp severity_id(verdict) do
    score = number(value(verdict, :score), 0.0)

    cond do
      score >= 6.0 -> 5
      score >= 3.0 -> 4
      score >= 2.0 -> 3
      true -> 2
    end
  end

  defp severity_score(verdict) do
    value =
      verdict
      |> value(:score)
      |> number(0.0)
      |> Kernel.*(20.0)
      |> round()

    min(max(value, 1), 100)
  end

  defp observed_at(sample) do
    case value(sample, :observed_at_unix_nano) do
      value when is_integer(value) and value >= 0 ->
        case DateTime.from_unix(value, :nanosecond) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp device_uid(sample) do
    metadata = value(sample, :metadata) || %{}

    first_non_blank([
      metadata_value(metadata, "device_uid"),
      metadata_value(metadata, "device_id"),
      metadata_value(metadata, "host_id"),
      metadata_value(metadata, "agent_id"),
      metadata_value(metadata, "target_device_ip"),
      series_device(value(sample, :series_key)),
      value(sample, :series_key)
    ])
  end

  defp series_device("sysmon:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [_family, host | _] -> host
      _ -> nil
    end
  end

  defp series_device("snmp:" <> rest) do
    case String.split(rest, ":", parts: 5) do
      [_agent, _gateway, target | _] -> target
      _ -> nil
    end
  end

  defp series_device(series_key) when is_binary(series_key), do: series_key
  defp series_device(_series_key), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, metadata_atom_key(key)))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp metadata_atom_key("device_uid"), do: :device_uid
  defp metadata_atom_key("device_id"), do: :device_id
  defp metadata_atom_key("host_id"), do: :host_id
  defp metadata_atom_key("agent_id"), do: :agent_id
  defp metadata_atom_key("target_device_ip"), do: :target_device_ip
  defp metadata_atom_key(_key), do: :__serviceradar_unknown_metadata_key__

  defp subject_token(value) do
    value
    |> string_value()
    |> case do
      nil -> @event_type
      value -> String.replace(value, ~r/[.\s*>]/, "_")
    end
  end

  defp encode_order_key(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Jason.encode!()

  defp encode_order_key(value), do: string_value(value)

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp number(value, _default) when is_number(value), do: value * 1.0
  defp number(_value, default), do: default

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value), do: to_string(value)

  defp first_non_blank(values) do
    values
    |> Enum.map(&string_value/1)
    |> Enum.map(&trim_blank/1)
    |> Enum.find(&is_binary/1)
  end

  defp trim_blank(nil), do: nil

  defp trim_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = a3 |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    versioned_a4 = a4 |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end
end
