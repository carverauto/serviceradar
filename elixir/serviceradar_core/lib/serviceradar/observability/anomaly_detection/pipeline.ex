defmodule ServiceRadar.Observability.AnomalyDetection.Pipeline do
  @moduledoc """
  Broadway topology for live anomaly analysis samples.

  This consumer is intentionally separate from EventWriter DB-sync. It owns its
  own JetStream durable, uses `deliver_policy: :new`, and acks independently so
  analysis can be enabled without affecting persistence cursors.
  """

  use Broadway

  alias Broadway.Message
  alias ServiceRadar.EventWriter.Producer
  alias ServiceRadar.Observability.AnomalyDetection.Config
  alias ServiceRadar.Observability.AnomalyDetection.ContextEngine
  alias ServiceRadar.Observability.AnomalyDetection.CounterNormalizer
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor
  alias ServiceRadar.Observability.AnomalyDetection.VerdictEmitter

  require Logger

  @active_series_table __MODULE__.ActiveSeries

  @doc """
  Starts the analysis Broadway topology.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config) do
    Broadway.start_link(__MODULE__, broadway_options(config))
  end

  @doc false
  @spec broadway_options(Config.t()) :: keyword()
  def broadway_options(%Config{} = config) do
    [
      name: __MODULE__,
      context: config,
      producer: [
        module: {Producer, Config.to_event_writer_config(config)},
        transformer: {__MODULE__, :transform, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: config.processor_concurrency]
      ]
    ]
  end

  @doc """
  Transforms producer events into Broadway messages.
  """
  def transform(event, _opts) do
    %Message{
      data: event.data,
      metadata: event.metadata,
      acknowledger: {__MODULE__, :ack_ref, event.ack_data}
    }
  end

  @doc """
  Acknowledges processed messages back to JetStream.
  """
  def ack(:ack_ref, successful, failed) do
    Enum.each(successful, &ack_message(&1, :ack))
    Enum.each(failed, &ack_message(&1, :nack))
    :ok
  end

  @doc false
  def reset_active_series_for_test do
    case :ets.whereis(@active_series_table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    CounterNormalizer.reset_table()
  end

  @impl true
  def handle_message(_processor, %Message{} = message, %Config{} = config) do
    subject = subject(message)

    if Config.subject_enabled?(config, subject) do
      analyze_message(message, subject, config)
    else
      emit(:disabled, 1, subject)
      message
    end
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn message ->
      Logger.warning("Anomaly analysis message failed",
        subject: subject(message),
        reason: inspect(message.status)
      )
    end)

    messages
  end

  defp analyze_message(%Message{} = message, subject, %Config{} = config) do
    samples =
      message
      |> SampleExtractor.extract()
      |> CounterNormalizer.normalize_samples()

    case analyze_samples(samples, subject, config) do
      :ok ->
        emit(:analyzed, length(samples), subject)
        message

      {:drop, reason} ->
        emit(:dropped, 1, subject, reason)
        message

      {:error, reason} ->
        emit(:failed, 1, subject, reason)
        Message.failed(message, reason)
    end
  end

  defp analyze_samples([], _subject, _config), do: {:drop, :no_scalar_samples}

  defp analyze_samples(samples, subject, %Config{} = config) do
    samples
    |> evaluate_samples(config)
    |> Enum.reduce_while(:ok, fn {sample, result}, :ok ->
      case result do
        {:ok, verdict} ->
          case maybe_emit_verdict(sample, verdict) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:drop, reason} ->
          emit(:dropped, 1, subject, reason)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_samples(samples, %Config{} = config) do
    engine = context_engine(config)

    cond do
      function_exported?(engine, :evaluate_events_batch, 1) ->
        engine.evaluate_events_batch(samples)

      function_exported?(engine, :evaluate_batch, 1) ->
        samples
        |> engine.evaluate_batch()
        |> normalize_batch_results(samples)

      true ->
        Enum.map(samples, &{&1, engine.evaluate(&1)})
    end
  end

  defp normalize_batch_results(results, samples) when is_list(results) do
    samples
    |> Enum.zip(results)
    |> Enum.map(fn {sample, result} -> {sample, result} end)
  end

  defp normalize_batch_results(result, samples) do
    Enum.map(samples, &{&1, {:error, {:unexpected_anomaly_batch_result, result}}})
  end

  defp maybe_emit_verdict(sample, verdict) do
    cond do
      anomalous?(verdict) and not suppressed?(verdict) ->
        case emit_verdict(sample, verdict) do
          :ok ->
            mark_active(sample)
            :ok

          {:error, _reason} = error ->
            error
        end

      clearing_verdict?(verdict) and should_emit_clear?(sample) ->
        case emit_verdict(sample, verdict) do
          :ok ->
            mark_inactive(sample)
            :ok

          {:error, _reason} = error ->
            error
        end

      true ->
        :ok
    end
  end

  defp emit_verdict(sample, verdict) do
    case verdict_emitter().emit(sample, verdict) do
      :ok -> :ok
      {:error, reason} -> {:error, {:anomaly_verdict_emit_failed, reason}}
      other -> {:error, {:unexpected_anomaly_verdict_emit_result, other}}
    end
  end

  defp clearing_verdict?(verdict) when is_map(verdict),
    do: suppressed?(verdict) or normal_state?(verdict)

  defp clearing_verdict?(_verdict), do: false

  defp should_emit_clear?(sample) do
    sample
    |> active_series_key()
    |> case do
      nil ->
        false

      key ->
        case :ets.lookup(active_series_table(), key) do
          [{^key, :inactive}] -> false
          _ -> true
        end
    end
  end

  defp mark_active(sample) do
    case active_series_key(sample) do
      nil -> :ok
      key -> :ets.insert(active_series_table(), {key, :active})
    end
  end

  defp mark_inactive(sample) do
    case active_series_key(sample) do
      nil -> :ok
      key -> :ets.insert(active_series_table(), {key, :inactive})
    end
  end

  defp active_series_key(sample) when is_map(sample) do
    sample
    |> Map.get(:series_key, Map.get(sample, "series_key"))
    |> case do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      value when not is_nil(value) ->
        to_string(value)

      _ ->
        nil
    end
  end

  defp active_series_key(_sample), do: nil

  defp active_series_table do
    case :ets.whereis(@active_series_table) do
      :undefined ->
        try do
          :ets.new(@active_series_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            @active_series_table
        end

      table ->
        table
    end
  end

  defp anomalous?(verdict) when is_map(verdict) do
    Map.get(verdict, :anomalous, Map.get(verdict, "anomalous", false)) == true
  end

  defp anomalous?(_verdict), do: false

  defp suppressed?(verdict) when is_map(verdict) do
    Map.get(verdict, :suppressed, Map.get(verdict, "suppressed", false)) == true
  end

  defp suppressed?(_verdict), do: false

  defp normal_state?(verdict) when is_map(verdict) do
    state =
      verdict
      |> Map.get(:state, Map.get(verdict, "state"))
      |> to_string()
      |> String.downcase()

    state in ["normal", "ok", "healthy", "resolved", "inactive", "closed", "cleared", "clean"]
  end

  defp normal_state?(_verdict), do: false

  defp context_engine(%Config{context_engine: configured_engine}) do
    Application.get_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      configured_engine || ContextEngine
    )
  end

  defp verdict_emitter do
    Application.get_env(
      :serviceradar_core,
      :anomaly_detection_verdict_emitter,
      VerdictEmitter
    )
  end

  defp subject(%Message{metadata: metadata}) when is_map(metadata) do
    metadata[:base_subject] || metadata[:subject] || ""
  end

  defp subject(_message), do: ""

  defp emit(event, count, subject, reason \\ nil) do
    :telemetry.execute(
      [:serviceradar, :anomaly_detection, :consumer, event],
      %{count: count},
      %{subject: subject, reason: reason}
    )
  end

  defp ack_message(%{acknowledger: {_, _, ack_data}} = message, action) do
    case ack_data[:ack_fun] do
      ack_fun when is_function(ack_fun, 1) ->
        case safe_invoke_ack(ack_fun, action) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug("Failed to publish anomaly analysis ack",
              action: action,
              reason: inspect(reason),
              subject: message.metadata[:subject],
              reply_to: message.metadata[:reply_to]
            )
        end

      _ ->
        :ok
    end
  end

  defp ack_message(_message, _action), do: :ok

  defp safe_invoke_ack(ack_fun, action) when is_function(ack_fun, 1) do
    case ack_fun.(action) do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  rescue
    error ->
      {:error, error}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}

    kind, reason ->
      {:error, {kind, reason}}
  end
end
