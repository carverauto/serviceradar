defmodule ServiceRadarAgentGateway.MetricsPublisher do
  @moduledoc """
  Shared base for the per-metric-type protobuf `MetricBatch` publishers.

  The 6 metric publishers (sysmon, snmp, icmp, rperf, mtr, sweep) shared a
  byte-for-byte identical body modulo a handful of per-type tokens. This module
  exposes a `__using__/1` macro that injects that common body into each
  publisher, parameterized by the metric type and the few values that genuinely
  differ per publisher. Each publisher therefore stays a distinct, real module
  (callers resolve them by name and call `publish_<type>/1`), but carries zero
  duplicated logic.

  ## Options

    * `:metric` (required) — the metric-type atom, e.g. `:sysmon`. Drives the
      `publish_<type>/1` function name, the `:<type>_metrics_publisher`
      config key, the `:missing_<type>_message` decode error, the
      `"metrics.<type>"` default subject prefix and the `"<type>-metrics"`
      ingest source.
    * `:log_label` (required) — display label used in the publish-error log
      message, e.g. `"SNMP"` or `"sysmon"`.
    * `:producer_kind` (optional, default `"agent"`) — the producer kind stamped
      onto the attested ingest identity, e.g. `"rperf-checker"`.
    * `:descriptor` (optional, default the metric token) — human descriptor used
      in the generated moduledoc, e.g. `"SNMP"` or `"MTR scalar"`.
  """

  defmacro __using__(opts) do
    metric = Keyword.fetch!(opts, :metric)
    log_label = Keyword.fetch!(opts, :log_label)
    producer_kind = Keyword.get(opts, :producer_kind, "agent")

    token = Atom.to_string(metric)
    descriptor = Keyword.get(opts, :descriptor, token)
    publish_fn = String.to_atom("publish_#{token}")
    config_key = String.to_atom("#{token}_metrics_publisher")
    missing_atom = String.to_atom("missing_#{token}_message")

    quote bind_quoted: [
            token: token,
            descriptor: descriptor,
            log_label: log_label,
            producer_kind: producer_kind,
            publish_fn: publish_fn,
            config_key: config_key,
            missing_atom: missing_atom
          ] do
      @moduledoc """
      Publishes protobuf #{descriptor} metric batches to the high-rate metrics stream.
      """

      alias Serviceradar.Metric.V1.MetricBatch
      alias ServiceRadarAgentGateway.IngressId
      alias ServiceRadarAgentGateway.MetricEnvelopeAttestation

      require Logger

      @app :serviceradar_agent_gateway
      @config_key config_key
      @default_subject_prefix "metrics.#{token}"
      @metric_schema "serviceradar.metric.v1"
      @source "#{token}-metrics"
      @producer_kind producer_kind
      @missing_message missing_atom
      @log_label log_label

      @type publish_result :: :ok | :disabled | {:error, term()}

      @spec unquote(publish_fn)(map()) :: publish_result()
      def unquote(publish_fn)(status) do
        config = config()

        if Keyword.get(config, :enabled, false) do
          do_publish(status, config)
        else
          :disabled
        end
      end

      defp do_publish(status, config) do
        with {:ok, %MetricBatch{} = batch} <- decode_metric_batch(status[:message]),
             :ok <- validate_metric_batch(batch) do
          ingress_context = ingress_context(status)

          batch =
            MetricEnvelopeAttestation.attest(batch, status, ingress_context,
              source: @source,
              producer_id: status[:agent_id],
              producer_kind: @producer_kind
            )

          publish_message(subject(batch), MetricBatch.encode(batch), ingress_context, config)
        else
          {:error, reason} = error -> log_publish_error(reason, status, error)
        end
      end

      defp config do
        Application.get_env(@app, @config_key, [])
      end

      defp decode_metric_batch(message) when is_binary(message) do
        {:ok, MetricBatch.decode(message)}
      rescue
        _ -> {:error, :invalid_metric_batch_payload}
      end

      defp decode_metric_batch(_message), do: {:error, @missing_message}

      defp validate_metric_batch(%MetricBatch{schema_version: @metric_schema, metrics: [_ | _]}), do: :ok
      defp validate_metric_batch(_batch), do: {:error, :invalid_metric_batch_schema}

      defp subject(%MetricBatch{metrics: [metric | _]}) do
        metric_type = normalize_string(metric.metric_type) || "custom"
        metric_name = normalize_string(metric.name) || "unknown"
        type = safe_subject_token(metric_type) || "custom"
        name = safe_subject_token(metric_name) || "unknown"

        "#{@default_subject_prefix}.#{type}.#{name}"
      end

      defp subject(_batch), do: "#{@default_subject_prefix}.custom.unknown"

      defp publish_message(subject, payload, ingress_context, config) do
        connection = Keyword.get(config, :connection, ServiceRadar.NATS.Connection)
        subject_prefix = Keyword.get(config, :subject_prefix, @default_subject_prefix)
        configured_headers = Keyword.get(config, :headers, [])
        subject = String.replace_prefix(subject, @default_subject_prefix, subject_prefix)
        headers = configured_headers ++ IngressId.headers(ingress_context)

        case connection.publish(subject, payload, headers: headers) do
          :ok -> :ok
          {:error, reason} -> {:error, {:publish_failed, [{subject, reason}]}}
        end
      end

      defp normalize_string(nil), do: nil
      defp normalize_string(value) when is_binary(value), do: String.trim(value)
      defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
      defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
      defp normalize_string(_value), do: nil

      defp safe_subject_token(value) do
        value
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_-]+/, "_")
        |> String.trim("_")
        |> case do
          "" -> nil
          token -> token
        end
      end

      defp log_publish_error(reason, status, error) do
        Logger.warning("Failed to publish #{@log_label} metrics",
          reason: inspect(reason),
          agent_id: status[:agent_id],
          gateway_id: status[:gateway_id],
          partition: status[:partition]
        )

        error
      end

      defp ingress_context(status) do
        ingress_time = System.system_time(:nanosecond)
        agent_id = status[:agent_id]

        %{
          ingress_time_unix_nano: ingress_time,
          ingress_id: IngressId.new(ingress_time),
          agent_id: agent_id,
          gateway_id: status[:gateway_id],
          partition: status[:partition],
          ingest_identity: if(agent_id, do: "agent:" <> to_string(agent_id))
        }
      end
    end
  end
end
