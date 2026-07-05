defmodule ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter do
  @moduledoc """
  Emits central-seasonal anomaly dispositions through the analytics signal spine.

  A confirmed `SeasonalBreach` from the NIF surfaces here as a `signal_type: "prediction"`
  anomaly verdict (see `payload/2`) carrying its `series_key` and the time window of the
  bucket under test, with `verdict_source: central-seasonal` so the edge + central tiers compose
  on the existing `source` join contract (design "composed, not merged"). Mirrors
  `ServiceRadar.Observability.CapacityForecasting.VerdictEmitter`; the OCSF re-key
  and alert-enqueue sink downstream are untouched.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Observability.CausalPredictionSubject

  @event_type "anomaly"
  @provider "seasonal_disposition"
  @verdict_source "central-seasonal"

  @spec emit(map(), keyword()) :: :ok | {:error, term()}
  def emit(attrs, opts \\ []) when is_map(attrs) do
    subject = subject(attrs)
    payload = payload(attrs, subject)
    publish_opts = Keyword.get(opts, :publish_opts, [])
    publisher = Keyword.get(opts, :publisher, &Connection.publish/3)

    publisher.(subject, Jason.encode!(payload), publish_opts)
  end

  @spec payload(map()) :: map()
  def payload(attrs) when is_map(attrs), do: payload(attrs, subject(attrs))

  @spec payload(map(), String.t()) :: map()
  def payload(attrs, subject) when is_map(attrs) and is_binary(subject) do
    %{
      "event_id" => event_id(attrs),
      "signal_type" => "prediction",
      "event_type" => @event_type,
      "verdict_source" => @verdict_source,
      "status" => status(attrs),
      "finding_type" => "detection",
      "class_uid" => 2004,
      "signal_domain" => "health",
      "signal_domains" => ["health"],
      "timestamp" => iso8601(Map.get(attrs, :bucket_ended_at) || Map.get(attrs, :evaluated_at)),
      "severity_id" => severity_id(attrs),
      "provider" => @provider,
      "source" => "serviceradar",
      "collector" => "seasonal_disposition_worker",
      "device_id" => string_value(Map.get(attrs, :resource_id)),
      "device_uid" => string_value(Map.get(attrs, :resource_id)),
      "message" => message(attrs),
      "finding_info" => finding_info(attrs),
      "anomaly" => anomaly_payload(attrs),
      "seasonal_disposition" => seasonal_payload(attrs),
      "explainability" => %{
        "classification" => @event_type,
        "verdict_source" => @verdict_source,
        "reason" => reason(attrs),
        "severity_score" => severity_score(attrs)
      },
      "source_identity" => %{
        "entity_uid" => string_value(Map.get(attrs, :resource_id)),
        "resource_key" => string_value(Map.get(attrs, :series_key))
      },
      "routing_correlation" => %{
        "record_id" => string_value(Map.get(attrs, :series_key)),
        "topology_keys" =>
          [Map.get(attrs, :resource_id), Map.get(attrs, :series_key)]
          |> Enum.map(&string_value/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
      },
      "source_subject" => subject
    }
  end

  defp anomaly_payload(attrs) do
    %{
      "series_key" => string_value(Map.get(attrs, :series_key)),
      "metric_class" => string_value(Map.get(attrs, :metric_class)),
      "metric_name" => string_value(Map.get(attrs, :metric_name)),
      "state" => anomaly_state(attrs),
      "detector_state" => status(attrs),
      "score" => Map.get(attrs, :score),
      "reason" => reason(attrs),
      "verdict_source" => @verdict_source
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp finding_info(attrs) do
    uid = finding_uid(attrs)
    series_key = string_value(Map.get(attrs, :series_key))
    resource_id = string_value(Map.get(attrs, :resource_id))
    metric_name = string_value(Map.get(attrs, :metric_name))

    %{
      "uid" => uid,
      "group_uid" => uid,
      "title" => "Seasonal anomaly: #{metric_name || "metric"} #{series_key || "series"}",
      "type" => "ServiceRadar Seasonal Anomaly",
      "type_id" => 99,
      "source" => @provider,
      "dimensions" =>
        %{
          "class_uid" => 2004,
          "source" => @provider,
          "verdict_source" => @verdict_source,
          "series_key" => series_key,
          "resource_id" => resource_id,
          "metric_class" => string_value(Map.get(attrs, :metric_class)),
          "metric_name" => metric_name,
          "dow" => Map.get(attrs, :dow),
          "hod" => Map.get(attrs, :hod)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp finding_uid(attrs) do
    stable_key =
      Enum.map_join(
        [
          @event_type,
          @verdict_source,
          2004,
          @provider,
          Map.get(attrs, :resource_id),
          Map.get(attrs, :series_key),
          Map.get(attrs, :metric_name)
        ],
        ":",
        &string_value/1
      )

    :sha256
    |> :crypto.hash("seasonal_disposition:finding:#{stable_key}")
    |> binary_part(0, 16)
    |> Ecto.UUID.load!()
  end

  @spec subject(map()) :: String.t()
  def subject(attrs) when is_map(attrs) do
    CausalPredictionSubject.build(Map.get(attrs, :series_key), @event_type)
  end

  @spec event_id(map()) :: String.t()
  def event_id(attrs) when is_map(attrs) do
    Enum.map_join(
      [
        @event_type,
        @verdict_source,
        finding_uid(attrs)
      ],
      ":",
      &string_value/1
    )
  end

  defp seasonal_payload(attrs) do
    %{
      "series_key" => string_value(Map.get(attrs, :series_key)),
      "resource_type" => string_value(Map.get(attrs, :resource_type)),
      "resource_id" => string_value(Map.get(attrs, :resource_id)),
      "resource_label" => string_value(Map.get(attrs, :resource_label)),
      "metric_class" => string_value(Map.get(attrs, :metric_class)),
      "metric_name" => string_value(Map.get(attrs, :metric_name)),
      "verdict_source" => @verdict_source,
      "disposition" => string_value(Map.get(attrs, :disposition)),
      "score" => Map.get(attrs, :score),
      "consecutive_anomalous" => Map.get(attrs, :consecutive_anomalous),
      "dow" => Map.get(attrs, :dow),
      "hod" => Map.get(attrs, :hod),
      "evaluated_at" => iso8601(Map.get(attrs, :evaluated_at)),
      "bucket_started_at" => iso8601(Map.get(attrs, :bucket_started_at)),
      "bucket_ended_at" => iso8601(Map.get(attrs, :bucket_ended_at)),
      "sample_value" => Map.get(attrs, :sample_value),
      "status" => status(attrs),
      "metadata" => Map.get(attrs, :metadata) || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp message(attrs) do
    label =
      Map.get(attrs, :resource_label) ||
        Map.get(attrs, :series_key) ||
        Map.get(attrs, :resource_id) ||
        "series"

    metric = Map.get(attrs, :metric_name) || "metric"
    score = Map.get(attrs, :score)
    score_text = if is_number(score), do: " (residual z=#{format_number(score)})", else: ""

    if active?(attrs) do
      "Seasonal anomaly: #{label} #{metric} breached its hour-of-week baseline#{score_text}"
    else
      "Seasonal anomaly cleared: #{label} #{metric} is within its hour-of-week baseline"
    end
  end

  defp reason(attrs) do
    Enum.join(
      [
        "disposition=#{string_value(Map.get(attrs, :disposition))}",
        "score=#{format_number(Map.get(attrs, :score))}",
        "consecutive_anomalous=#{format_number(Map.get(attrs, :consecutive_anomalous))}",
        "dow=#{format_number(Map.get(attrs, :dow))}",
        "hod=#{format_number(Map.get(attrs, :hod))}"
      ],
      " "
    )
  end

  defp status(attrs), do: attrs |> Map.get(:status) |> string_value() |> default_status()

  defp default_status(nil), do: "breach"
  defp default_status(""), do: "breach"
  defp default_status(status), do: status

  defp anomaly_state(attrs) do
    case status(attrs) do
      "breach" -> "anomaly_open"
      state when state in ["cleared", "inactive", "resolved", "closed"] -> "anomaly_clear"
      state -> state
    end
  end

  defp active?(attrs), do: status(attrs) == "breach"

  defp severity_id(%{status: status}) when status in ["inactive", "resolved", "cleared"], do: 2

  defp severity_id(attrs) do
    case Map.get(attrs, :score) do
      score when is_number(score) and score >= 8.0 -> 4
      score when is_number(score) and score >= 4.0 -> 3
      _ -> 2
    end
  end

  defp severity_score(attrs) do
    case severity_id(attrs) do
      4 -> 75
      3 -> 55
      2 -> 20
      _ -> 0
    end
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value), do: to_string(value)

  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 4)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(nil), do: "unknown"
  defp format_number(value), do: to_string(value)
end
