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
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor
  alias ServiceRadar.Observability.AnomalyDetection.VerdictEmitter

  require Logger

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

  @impl true
  def handle_message(_processor, %Message{} = message, %Config{} = config) do
    subject = subject(message)

    if Config.subject_enabled?(config, subject) do
      analyze_message(message, subject)
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

  defp analyze_message(%Message{} = message, subject) do
    samples = SampleExtractor.extract(message)

    case analyze_samples(samples, subject) do
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

  defp analyze_samples([], _subject), do: {:drop, :no_scalar_samples}

  defp analyze_samples(samples, subject) do
    Enum.reduce_while(samples, :ok, fn sample, :ok ->
      case context_engine().evaluate(sample) do
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

  defp maybe_emit_verdict(sample, verdict) do
    if anomalous?(verdict) and not suppressed?(verdict) do
      case verdict_emitter().emit(sample, verdict) do
        :ok -> :ok
        {:error, reason} -> {:error, {:anomaly_verdict_emit_failed, reason}}
        other -> {:error, {:unexpected_anomaly_verdict_emit_result, other}}
      end
    else
      :ok
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

  defp context_engine do
    Application.get_env(
      :serviceradar_core,
      :anomaly_detection_context_engine,
      ContextEngine
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
