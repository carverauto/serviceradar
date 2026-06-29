defmodule ServiceRadar.Observability.CapacityForecasting.VerdictEmitter do
  @moduledoc """
  Emits at-risk capacity forecasts through the causal signal spine.
  """

  alias ServiceRadar.NATS.Connection
  alias ServiceRadar.Observability.CausalPredictionSubject

  @event_type "capacity_forecast"
  @provider "capacity_forecasting"

  @spec emit(map(), keyword()) :: :ok | {:error, term()}
  def emit(attrs, opts \\ []) when is_map(attrs) do
    subject = subject(attrs)
    payload = payload(attrs, subject)
    publish_opts = Keyword.get(opts, :publish_opts, [])
    publisher = Keyword.get(opts, :publisher, &Connection.publish/3)

    publisher.(subject, Jason.encode!(payload), publish_opts)
  end

  @spec payload(map(), String.t()) :: map()
  def payload(attrs) when is_map(attrs), do: payload(attrs, subject(attrs))

  def payload(attrs, subject) when is_map(attrs) and is_binary(subject) do
    exhaustion_at = Map.get(attrs, :projected_exhaustion_at)

    %{
      "event_id" => event_id(attrs),
      "signal_type" => "prediction",
      "event_type" => @event_type,
      "status" => status(attrs),
      "finding_type" => "detection",
      "class_uid" => 2004,
      "signal_domain" => "health",
      "signal_domains" => ["health"],
      "timestamp" => iso8601(Map.get(attrs, :forecasted_at)),
      "severity_id" => severity_id(attrs),
      "provider" => @provider,
      "source" => "serviceradar",
      "collector" => "capacity_forecasting_worker",
      "device_id" => string_value(Map.get(attrs, :resource_id)),
      "device_uid" => string_value(Map.get(attrs, :resource_id)),
      "message" => message(attrs, exhaustion_at),
      "finding_info" => finding_info(attrs),
      "capacity_forecast" => capacity_payload(attrs),
      "explainability" => %{
        "classification" => @event_type,
        "reason" => reason(attrs, exhaustion_at),
        "severity_score" => severity_score(attrs)
      },
      "source_identity" => %{
        "entity_uid" => string_value(Map.get(attrs, :resource_id)),
        "resource_key" => string_value(Map.get(attrs, :resource_key))
      },
      "routing_correlation" => %{
        "record_id" => string_value(Map.get(attrs, :resource_key)),
        "topology_keys" =>
          [Map.get(attrs, :resource_id), Map.get(attrs, :resource_key)]
          |> Enum.map(&string_value/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
      },
      "source_subject" => subject
    }
  end

  defp finding_info(attrs) do
    uid = finding_uid(attrs)
    resource_key = string_value(Map.get(attrs, :resource_key))
    resource_id = string_value(Map.get(attrs, :resource_id))
    metric_name = string_value(Map.get(attrs, :metric_name))

    %{
      "uid" => uid,
      "group_uid" => uid,
      "title" => "Capacity forecast: #{metric_name || "capacity"} #{resource_key || "resource"}",
      "type" => "ServiceRadar Capacity Forecast",
      "type_id" => 99,
      "source" => @provider,
      "dimensions" =>
        %{
          "class_uid" => 2004,
          "source" => @provider,
          "resource_key" => resource_key,
          "resource_id" => resource_id,
          "metric_class" => string_value(Map.get(attrs, :metric_class)),
          "metric_name" => metric_name,
          "horizon_seconds" => Map.get(attrs, :horizon_seconds)
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
          2004,
          @provider,
          Map.get(attrs, :resource_id),
          Map.get(attrs, :resource_key),
          Map.get(attrs, :metric_name),
          Map.get(attrs, :horizon_seconds)
        ],
        ":",
        &string_value/1
      )

    :sha256
    |> :crypto.hash("capacity_forecast:finding:#{stable_key}")
    |> binary_part(0, 16)
    |> Ecto.UUID.load!()
  end

  @spec subject(map()) :: String.t()
  def subject(attrs) when is_map(attrs) do
    CausalPredictionSubject.build(Map.get(attrs, :resource_key), @event_type)
  end

  @spec event_id(map()) :: String.t()
  def event_id(attrs) when is_map(attrs) do
    Enum.map_join(
      [
        @event_type,
        finding_uid(attrs)
      ],
      ":",
      &string_value/1
    )
  end

  defp capacity_payload(attrs) do
    finding_uid = finding_uid(attrs)

    %{
      "finding_uid" => finding_uid,
      "clears_finding_uid" => cleared_finding_uid(attrs, finding_uid),
      "resource_key" => string_value(Map.get(attrs, :resource_key)),
      "resource_type" => string_value(Map.get(attrs, :resource_type)),
      "resource_id" => string_value(Map.get(attrs, :resource_id)),
      "resource_label" => string_value(Map.get(attrs, :resource_label)),
      "metric_class" => string_value(Map.get(attrs, :metric_class)),
      "metric_name" => string_value(Map.get(attrs, :metric_name)),
      "forecasted_at" => iso8601(Map.get(attrs, :forecasted_at)),
      "horizon_seconds" => Map.get(attrs, :horizon_seconds),
      "horizon_ends_at" => iso8601(Map.get(attrs, :horizon_ends_at)),
      "window_started_at" => iso8601(Map.get(attrs, :window_started_at)),
      "window_ended_at" => iso8601(Map.get(attrs, :window_ended_at)),
      "sample_count" => Map.get(attrs, :sample_count),
      "model" => string_value(Map.get(attrs, :model)),
      "status" => string_value(Map.get(attrs, :status)),
      "current_value" => Map.get(attrs, :current_value),
      "projected_value" => Map.get(attrs, :projected_value),
      "projected_exhaustion_at" => iso8601(Map.get(attrs, :projected_exhaustion_at)),
      "exhaustion_threshold" => Map.get(attrs, :exhaustion_threshold),
      "confidence" => Map.get(attrs, :confidence),
      "lower_bound" => Map.get(attrs, :lower_bound),
      "upper_bound" => Map.get(attrs, :upper_bound),
      "metadata" => Map.get(attrs, :metadata) || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp cleared_finding_uid(attrs, finding_uid) do
    if active?(attrs), do: nil, else: finding_uid
  end

  defp message(attrs, exhaustion_at) do
    label =
      Map.get(attrs, :resource_label) ||
        Map.get(attrs, :resource_key) ||
        Map.get(attrs, :resource_id) ||
        "resource"

    metric = Map.get(attrs, :metric_name) || "capacity"
    threshold = Map.get(attrs, :exhaustion_threshold)
    threshold_text = if is_number(threshold), do: " #{threshold}", else: ""

    if active?(attrs) do
      "Capacity forecast: #{label} #{metric} projected to cross#{threshold_text} at #{iso8601(exhaustion_at)}"
    else
      "Capacity forecast cleared: #{label} #{metric} is not projected to cross#{threshold_text}"
    end
  end

  defp reason(attrs, exhaustion_at) do
    current = Map.get(attrs, :current_value)
    projected = Map.get(attrs, :projected_value)
    threshold = Map.get(attrs, :exhaustion_threshold)

    Enum.join(
      [
        "projected_exhaustion_at=#{iso8601(exhaustion_at)}",
        "current_value=#{format_number(current)}",
        "projected_value=#{format_number(projected)}",
        "threshold=#{format_number(threshold)}"
      ],
      " "
    )
  end

  defp status(attrs), do: attrs |> Map.get(:status) |> string_value() |> default_status()

  defp default_status(nil), do: "projected"
  defp default_status(""), do: "projected"
  defp default_status(status), do: status

  defp active?(attrs), do: status(attrs) == "projected"

  defp severity_id(%{status: status})
       when status in ["inactive", "resolved", "closed", "skipped"], do: 2

  defp severity_id(%{
         forecasted_at: %DateTime{} = forecasted_at,
         projected_exhaustion_at: %DateTime{} = exhaustion_at
       }) do
    seconds_to_exhaustion = max(DateTime.diff(exhaustion_at, forecasted_at, :second), 0)

    cond do
      seconds_to_exhaustion <= 24 * 60 * 60 -> 5
      seconds_to_exhaustion <= 7 * 24 * 60 * 60 -> 4
      true -> 3
    end
  end

  defp severity_id(_attrs), do: 3

  defp severity_score(attrs) do
    case severity_id(attrs) do
      5 -> 90
      4 -> 75
      3 -> 55
      2 -> 20
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
