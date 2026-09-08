defmodule ServiceRadar.Observability.ObanFailureEventReporter do
  @moduledoc """
  Records Oban job exceptions as OCSF events.

  Oban Web is useful during an investigation, but production job failures need
  to appear in the same event stream as other operational failures. This process
  attaches to Oban telemetry and records retryable/discarded job failures without
  blocking the worker process that emitted the telemetry event.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring
  alias ServiceRadar.Monitoring.OcsfEvent

  require Logger

  @handler_id {__MODULE__, :oban_job_exception}
  @event_name [:oban, :job, :exception]
  @redacted "[REDACTED]"
  @secret_key_fragments ~w(password passwd secret token api_key apikey access_key private_key credential credentials auth authorization cookie)
  @max_string_length 2_000
  @max_collection_items 25
  @max_stacktrace_frames 8

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled, true)

    if enabled? do
      :telemetry.detach(@handler_id)

      :telemetry.attach(
        @handler_id,
        @event_name,
        &__MODULE__.handle_telemetry_event/4,
        %{pid: self()}
      )

      Logger.debug("Oban failure event reporter attached")
    end

    {:ok, %{enabled?: enabled?, record_event: Keyword.get(opts, :record_event, &record_event/2)}}
  end

  @impl GenServer
  def terminate(_reason, %{enabled?: true}) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def handle_telemetry_event(_event, measurements, metadata, %{pid: pid}) when is_pid(pid) do
    send(pid, {:oban_job_exception, measurements, metadata})
    :ok
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config), do: :ok

  @spec record_job_failure(Oban.Job.t(), atom(), term(), list(), map()) ::
          {:ok, struct()} | {:error, term()}
  def record_job_failure(%Oban.Job{} = job, kind, reason, stacktrace \\ [], measurements \\ %{}) do
    actor = SystemActor.system(:oban_failure_event_reporter)
    job |> build_event_attrs(kind, reason, stacktrace, measurements) |> record_event(actor)
  end

  @impl GenServer
  def handle_info({:oban_job_exception, measurements, metadata}, state) do
    job = Map.get(metadata, :job)
    kind = Map.get(metadata, :kind, :error)
    reason = Map.get(metadata, :reason)
    stacktrace = Map.get(metadata, :stacktrace, [])

    if job do
      attrs = build_event_attrs(job, kind, reason, stacktrace, measurements)
      actor = SystemActor.system(:oban_failure_event_reporter)

      case state.record_event.(attrs, actor) do
        {:ok, _event} ->
          :ok

        {:error, error} ->
          Logger.warning("Failed to record Oban failure event", error: inspect(error))
      end
    end

    {:noreply, state}
  rescue
    error ->
      Logger.warning("Oban failure event reporter crashed while handling telemetry",
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      {:noreply, state}
  end

  @spec build_event_attrs(Oban.Job.t(), atom(), term(), list(), map()) :: map()
  def build_event_attrs(%Oban.Job{} = job, kind, reason, stacktrace, measurements \\ %{}) do
    activity_id = OCSF.activity_log_update()
    severity_id = severity_id(job)
    status_code = status_code(job)
    status_detail = reason_summary(kind, reason)

    raw_data = %{
      "event_family" => "oban_job_failure",
      "job_id" => job.id,
      "queue" => job.queue,
      "worker" => job.worker,
      "state" => job.state,
      "attempt" => job.attempt,
      "max_attempts" => job.max_attempts,
      "status_code" => status_code,
      "kind" => to_string(kind || :error),
      "reason" => status_detail,
      "args" => redact(job.args || %{}),
      "meta" => redact(job.meta || %{}),
      "measurements" => normalize_measurements(measurements),
      "stacktrace" => format_stacktrace(stacktrace)
    }

    %{
      class_uid: OCSF.class_event_log_activity(),
      category_uid: OCSF.category_system_activity(),
      type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
      activity_id: activity_id,
      activity_name: OCSF.log_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      status_id: OCSF.status_failure(),
      status: OCSF.status_name(OCSF.status_failure()),
      status_code: status_code,
      status_detail: status_detail,
      message: failure_message(job, status_detail),
      metadata:
        [product_name: "Oban", correlation_uid: job_id_string(job.id)]
        |> OCSF.build_metadata()
        |> Map.put(:event_family, "oban_job_failure"),
      observables: observables(job),
      actor: OCSF.build_actor(app_name: "serviceradar_core", process: job.worker),
      log_name: "serviceradar.oban",
      log_provider: "serviceradar_core",
      log_level: log_level(severity_id),
      raw_data: Jason.encode!(raw_data)
    }
  end

  defp record_event(attrs, actor) do
    OcsfEvent
    |> Ash.Changeset.for_create(:record, attrs, actor: actor)
    |> Ash.create(domain: Monitoring)
    |> case do
      {:ok, event} = ok ->
        ServiceRadar.Events.PubSub.broadcast_event(event)
        ok

      {:error, _error} = error ->
        error
    end
  end

  defp severity_id(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts) and attempt >= max_attempts do
    OCSF.severity_high()
  end

  defp severity_id(_job), do: OCSF.severity_medium()

  defp status_code(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts) and attempt >= max_attempts do
    "oban_job_discarded"
  end

  defp status_code(_job), do: "oban_job_retryable"

  defp log_level(severity_id) when severity_id >= 4, do: "error"
  defp log_level(_severity_id), do: "warning"

  defp failure_message(job, status_detail) do
    attempt =
      case {job.attempt, job.max_attempts} do
        {attempt, max_attempts} when is_integer(attempt) and is_integer(max_attempts) ->
          " attempt #{attempt}/#{max_attempts}"

        _ ->
          ""
      end

    "Oban job #{job.worker} failed on #{job.queue}#{attempt}: #{status_detail}"
  end

  defp reason_summary(kind, reason) do
    reason =
      case kind do
        :error -> Exception.message(reason)
        _ -> inspect(reason)
      end

    "#{kind || :error}: #{truncate(reason)}"
  rescue
    _error ->
      "#{kind || :error}: #{truncate(inspect(reason))}"
  end

  defp observables(job) do
    Enum.reject(
      [
        observable(job_id_string(job.id), "Oban Job ID"),
        observable(job.queue, "Oban Queue"),
        observable(job.worker, "Oban Worker")
      ],
      &is_nil/1
    )
  end

  defp observable(value, _name) when value in [nil, ""], do: nil

  defp observable(value, name) do
    %{"name" => name, "type" => "string", "value" => to_string(value)}
  end

  defp job_id_string(nil), do: nil
  defp job_id_string(id), do: to_string(id)

  defp normalize_measurements(measurements) when is_map(measurements) do
    Map.new(measurements, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_measurements(_measurements), do: %{}

  defp redact(%{} = map) do
    map
    |> Enum.take(@max_collection_items)
    |> Map.new(fn {key, value} ->
      if secret_key?(key) do
        {to_string(key), @redacted}
      else
        {to_string(key), redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list) do
    list
    |> Enum.take(@max_collection_items)
    |> Enum.map(&redact/1)
  end

  defp redact(value), do: normalize_value(value)

  defp secret_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    Enum.any?(@secret_key_fragments, &String.contains?(normalized, &1))
  end

  defp normalize_value(value) when is_binary(value), do: truncate(value)
  defp normalize_value(value) when is_atom(value), do: to_string(value)

  defp normalize_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(value), do: truncate(inspect(value))

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(@max_stacktrace_frames)
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  defp format_stacktrace(_stacktrace), do: []

  defp truncate(value) when is_binary(value) do
    if String.length(value) > @max_string_length do
      String.slice(value, 0, @max_string_length) <> "...[truncated]"
    else
      value
    end
  end
end
