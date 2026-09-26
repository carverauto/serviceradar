defmodule ServiceRadar.Events.OcsfEventPublisher do
  @moduledoc """
  The one way core produces an OCSF event.

  An event is published to JetStream on `events.internal.<family>` and stored
  by EventWriter (`ServiceRadar.EventWriter.Processors.Events`) in whichever
  telemetry backend is active, mirrored, and evaluated against stateful rules
  exactly like an event from any other source. Nothing in core inserts into
  `ocsf_events` itself.

  `publish/2`:

    1. builds the event from the `OcsfEvent` attributes, assigning `id` and
       `time` when absent, so the caller holds the event's identity before it
       is stored;
    2. suppresses an operational event for a device that is out of service;
    3. does not publish a synthetic liveness probe, which must never be stored;
    4. publishes durably (`ServiceRadar.NATS.DurablePublish`): a failed
       publish is retried from an Oban job rather than dropped;
    5. runs the northbound event handlers once the event is durable;
    6. returns `{:ok, %OcsfEvent{}}` with the id and every field.

  An event is visible to readers after the EventWriter batch interval, not on
  return.
  """

  alias ServiceRadar.Automation.Northbound.EventHandlerRunner
  alias ServiceRadar.Inventory.DeviceLifecycle
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.NATS.Channels
  alias ServiceRadar.NATS.DurablePublish

  require Logger

  # Subject families under `events.internal.`. A closed list: a family is a
  # compile-time choice of the producer, never operator input.
  @families %{
    alert: "alert",
    automation: "automation",
    camera: "camera",
    composite_check: "composite_check",
    credential: "credential",
    integration: "integration",
    inventory: "inventory",
    jobs: "jobs",
    observability: "observability"
  }

  @json_fields [
    :id,
    :time,
    :class_uid,
    :category_uid,
    :type_uid,
    :activity_id,
    :activity_name,
    :severity_id,
    :severity,
    :message,
    :status_id,
    :status,
    :status_code,
    :status_detail,
    :metadata,
    :observables,
    :trace_id,
    :span_id,
    :actor,
    :device,
    :src_endpoint,
    :dst_endpoint,
    :log_name,
    :log_provider,
    :log_level,
    :log_version,
    :unmapped,
    :raw_data
  ]

  @map_fields [:metadata, :actor, :device, :src_endpoint, :dst_endpoint, :unmapped]

  @type family ::
          :alert
          | :automation
          | :camera
          | :composite_check
          | :credential
          | :integration
          | :inventory
          | :jobs
          | :observability

  @doc """
  Publishes one OCSF event. `attrs` takes the `OcsfEvent` attribute names as
  atom keys.

  Returns `{:ok, event}`, `{:error, :suppressed}` for an out-of-service
  device, or `{:error, reason}` when the event could be neither published nor
  queued for retry.

  Options: `:family` (required), and for tests `:publish` (replaces
  `DurablePublish.publish/3`) and `:suppress?` (replaces the device check).
  """
  @spec publish(map(), keyword()) :: {:ok, OcsfEvent.t()} | {:error, :suppressed | term()}
  def publish(attrs, opts) when is_map(attrs) do
    family = Keyword.fetch!(opts, :family)
    subject = subject(family)
    event = build(attrs)

    cond do
      suppressed?(event, opts) ->
        {:error, :suppressed}

      synthetic_liveness_event?(event) ->
        {:ok, event}

      true ->
        durable_publish(event, subject, opts)
    end
  end

  @doc """
  Runs the northbound event handlers for a durable event. Handler events and
  synthetic probes never trigger handlers. A handler failure is logged and
  never propagates: the event is already stored.
  """
  @spec run_northbound_handlers(map() | OcsfEvent.t()) :: :ok
  def run_northbound_handlers(event) do
    event = if is_struct(event), do: event, else: from_json(event)

    if !northbound_handler_event?(event) and !synthetic_liveness_event?(event) do
      {:ok, _results} = EventHandlerRunner.handle_event(event)
    end

    :ok
  rescue
    exception ->
      Logger.warning("Failed to run northbound event handlers",
        event_id: Map.get(event, :id),
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  end

  @doc false
  # The subject an event of `family` is published on. An unknown family raises:
  # a producer names its family at compile time.
  def subject(family), do: Channels.build("events.internal." <> Map.fetch!(@families, family))

  defp durable_publish(event, subject, opts) do
    publish = Keyword.get(opts, :publish, &DurablePublish.publish/3)

    case publish.(subject, Jason.encode!(to_json(event)),
           msg_id: event.id,
           on_published: :northbound_handlers
         ) do
      :ok -> {:ok, event}
      {:ok, :enqueued} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  # The `OcsfEvent` attribute defaults, applied here because the event exists
  # before it is stored.
  defp build(attrs) do
    fields = Map.take(attrs, @json_fields)

    defaults =
      @map_fields
      |> Map.new(&{&1, %{}})
      |> Map.put(:observables, [])
      |> Map.put(:id, Ash.UUID.generate())
      |> Map.put(:time, DateTime.utc_now())

    fields =
      defaults
      |> Map.merge(fields, fn _field, default, value -> value || default end)
      |> Map.update!(:id, &canonical_id/1)

    struct(OcsfEvent, fields)
  end

  # Producers building rows for a raw insert carry the id as 16 raw bytes; the
  # event travels as JSON, so it is published in its canonical text form.
  defp canonical_id(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp canonical_id(id), do: id

  # Every field is sent, null included, so EventWriter stores exactly what the
  # producer set: it fills `log_name` and `raw_data` only when the key is
  # absent, as it does for external producers that omit them.
  defp to_json(event) do
    Map.new(@json_fields, fn field ->
      {Atom.to_string(field), json_value(Map.get(event, field))}
    end)
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(value), do: value

  defp from_json(json) when is_map(json) do
    fields =
      Map.new(@json_fields, fn field ->
        value = Map.get(json, Atom.to_string(field), Map.get(json, field))
        {field, from_json_value(field, value)}
      end)

    struct(OcsfEvent, fields)
  end

  defp from_json_value(:time, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp from_json_value(_field, value), do: value

  defp suppressed?(event, opts) do
    check = Keyword.get(opts, :suppress?, &DeviceLifecycle.suppress_operational_event?/1)

    check.(%{
      device: event.device,
      metadata: event.metadata,
      src_endpoint: event.src_endpoint,
      dst_endpoint: event.dst_endpoint
    })
  end

  @doc false
  def northbound_handler_event?(%{metadata: %{} = metadata}) do
    Map.get(metadata, "event_family") == "northbound_action_handler" ||
      Map.get(metadata, :event_family) == "northbound_action_handler"
  end

  def northbound_handler_event?(_event), do: false

  @doc false
  def synthetic_liveness_event?(%{metadata: %{} = metadata}) do
    serviceradar = Map.get(metadata, "serviceradar") || Map.get(metadata, :serviceradar) || %{}

    Map.get(serviceradar, "synthetic_liveness_check") == true ||
      Map.get(serviceradar, :synthetic_liveness_check) == true
  end

  def synthetic_liveness_event?(_event), do: false
end
