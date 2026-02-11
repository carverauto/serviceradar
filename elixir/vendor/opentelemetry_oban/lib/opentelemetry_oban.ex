defmodule OpentelemetryOban do
  @moduledoc """
  OpentelemetryOban uses [telemetry](https://hexdocs.pm/telemetry/) handlers to
  create `OpenTelemetry` spans from Oban events.

  Supported events include job start/stop and also when an exception is raised.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryOban.setup()

        # ...
      end
  """

  alias Ecto.Changeset
  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes, as: MessagingAttributes

  require OpenTelemetry.Tracer

  @doc """
  Initializes and configures telemetry handlers.

  By default jobs and plugins are traced. If you wish to trace only jobs then
  use:

      OpentelemetryOban.setup(trace: [:jobs])

  Note that if you don't trace plugins, but inside the plugins, there are spans
  from other instrumentation libraries (e.g. ecto) then these will still be
  traced. This setting controls only the spans that are created by
  opentelemetry_oban.
  """
  @spec setup() :: :ok
  def setup(opts \\ []) do
    trace = Keyword.get(opts, :trace, [:jobs, :plugins])

    if Enum.member?(trace, :jobs) do
      OpentelemetryOban.JobHandler.attach()
    end

    if Enum.member?(trace, :plugins) do
      OpentelemetryOban.PluginHandler.attach()
    end

    :ok
  end

  def insert(name \\ Oban, %Changeset{} = changeset) do
    attributes = attributes_before_insert(changeset)
    worker = Changeset.get_field(changeset, :worker)

    OpenTelemetry.Tracer.with_span "#{worker} send", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      case Oban.insert(name, changeset) do
        {:ok, job} ->
          OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
          {:ok, job}

        other ->
          other
      end
    end
  end

  def insert(name \\ Oban, multi, multi_name, changeset_or_fun) do
    Oban.insert(name, multi, multi_name, changeset_or_fun)
  end

  def insert!(name \\ Oban, %Changeset{} = changeset) do
    attributes = attributes_before_insert(changeset)
    worker = Changeset.get_field(changeset, :worker)

    OpenTelemetry.Tracer.with_span "#{worker} send", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      try do
        job = Oban.insert!(name, changeset)
        OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
        job
      rescue
        exception ->
          ctx = OpenTelemetry.Tracer.current_span_ctx()
          Span.record_exception(ctx, exception, __STACKTRACE__)
          Span.set_status(ctx, OpenTelemetry.status(:error, ""))
          reraise exception, __STACKTRACE__
      end
    end
  end

  def insert_all(name \\ Oban, changesets_or_wrapper)

  def insert_all(name, %{changesets: changesets}) when is_list(changesets) do
    insert_all(name, changesets)
  end

  def insert_all(name, changesets) when is_list(changesets) do
    # changesets in insert_all can include different workers and different
    # queues. This means we cannot provide much information here, but we can
    # still record the insert and propagate the context information.
    OpenTelemetry.Tracer.with_span :"Oban bulk insert", kind: :producer do
      changesets = Enum.map(changesets, &add_tracing_information_to_meta/1)
      Oban.insert_all(name, changesets)
    end
  end

  def insert_all(name \\ Oban, multi, multi_name, changesets_or_wrapper) do
    Oban.insert_all(name, multi, multi_name, changesets_or_wrapper)
  end

  defp add_tracing_information_to_meta(changeset) do
    meta = Changeset.get_field(changeset, :meta, %{})

    new_meta =
      []
      |> :otel_propagator_text_map.inject()
      |> Enum.into(meta)

    Changeset.change(changeset, %{meta: new_meta})
  end

  defp attributes_before_insert(changeset) do
    queue = Changeset.get_field(changeset, :queue)
    worker = Changeset.get_field(changeset, :worker)

    %{
      MessagingAttributes.messaging_system() => :oban,
      MessagingAttributes.messaging_destination_name() => queue,
      :"oban.job.worker" => worker
    }
  end

  defp attributes_after_insert(job) do
    %{
      "oban.job.job_id": job.id,
      "oban.job.priority": job.priority,
      "oban.job.max_attempts": job.max_attempts
    }
  end
end
