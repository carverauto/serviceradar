defmodule ServiceRadar.EventWriter.StateChangePublisher do
  @moduledoc """
  Publishes app-level state TRANSITIONS to `signals.state.<table>` NATS subjects
  for the causal engine to consume (OpenSpec change `add-causal-engine`,
  Decision 1: app-level NATS change-events).

  This is semantic transition publishing from application code — it is NOT
  pgoutput CDC, NOT logical replication, and it NEVER publishes TimescaleDB
  hypertables (those are queried on demand via SRQL). Each target current-state
  table hooks its own canonical write-site and calls `publish_transition/3` with
  the entity id plus before/after values.

  Identity discipline: callers pass the most canonical id they own for that
  table — the `sr:`-prefixed `uid` for `ocsf_devices`, the composite service
  identity for `service_state`, the writer's `entity_id` for `health_events`.
  The engine maps `(table, entity_uid)` into its single canonical ID space; this
  module does not invent ids.

  Disabled by default. Every hook site MUST guard its transition-detection work
  (e.g. pre-fetching previous state) behind `enabled?/0` so the feed adds zero
  overhead until `STATE_CHANGE_EVENTS_ENABLED` (or the application env
  `:state_change_events_enabled`) is turned on. Publishing is fire-and-forget:
  a NATS failure is logged, never raised, and never blocks the caller's write.
  """

  alias ServiceRadar.NATS.Connection

  require Logger

  @schema_version "1.0"
  @signal_type "state_change"
  @event_type "state_transition"
  @subject_prefix "signals.state."
  @telemetry [:serviceradar, :state_change, :published]

  @type transition_opt ::
          {:field, String.t()}
          | {:old, term()}
          | {:new, term()}
          | {:partition_id, String.t() | nil}
          | {:entity_type, String.t() | nil}
          | {:extra, map()}

  @doc """
  Whether the state-change feed is enabled. Controlled by the
  `STATE_CHANGE_EVENTS_ENABLED` env var or the `:state_change_events_enabled`
  application env (default `false`).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("STATE_CHANGE_EVENTS_ENABLED") in ["true", "1", "yes"] or
      Application.get_env(:serviceradar_core, :state_change_events_enabled, false)
  end

  @doc """
  Builds a transition envelope for `(table, entity_uid)` and publishes it to
  `signals.state.<table>`. No-ops when the feed is disabled or when `entity_uid`
  is not a usable (non-empty binary) identifier.
  """
  @spec publish_transition(String.t(), term(), [transition_opt()]) :: :ok
  def publish_transition(table, entity_uid, opts \\ []) when is_binary(table) do
    cond do
      not enabled?() ->
        :ok

      not usable_uid?(entity_uid) ->
        Logger.debug("state-change skipped: unusable entity id",
          table: table,
          entity_uid: inspect(entity_uid)
        )

        :ok

      true ->
        publish(table, build_envelope(table, entity_uid, opts))
    end
  end

  @doc """
  Publishes a pre-built envelope to `signals.state.<table>`. Self-gating on
  `enabled?/0`; never raises.
  """
  @spec publish(String.t(), map()) :: :ok
  def publish(table, envelope) when is_binary(table) and is_map(envelope) do
    if enabled?() do
      subject = @subject_prefix <> table

      # Producer span around the NATS hop: Connection.publish injects the
      # active span context into the message headers, so the causal-engine
      # consumer can continue this trace. Failures mark the span ERROR.
      ServiceRadar.Otel.span(
        "state_change.publish",
        %{
          kind: :producer,
          attributes: %{
            "messaging.system" => "nats",
            "messaging.destination.name" => subject,
            "serviceradar.state_change.table" => table
          }
        },
        fn ->
          case encode_and_publish(subject, envelope) do
            :ok ->
              :telemetry.execute(@telemetry, %{count: 1}, %{table: table, subject: subject})
              :ok

            {:error, reason} ->
              ServiceRadar.Otel.set_error(reason)

              Logger.warning("state-change publish failed",
                table: table,
                reason: inspect(reason)
              )

              :ok
          end
        end
      )
    else
      :ok
    end
  end

  @doc false
  @spec build_envelope(String.t(), binary(), [transition_opt()]) :: map()
  def build_envelope(table, uid, opts) when is_binary(table) and is_binary(uid) do
    field = Keyword.get(opts, :field)
    partition_id = Keyword.get(opts, :partition_id)
    entity_type = Keyword.get(opts, :entity_type)
    extra = Keyword.get(opts, :extra, %{})
    subject = @subject_prefix <> table

    %{
      "schema_version" => @schema_version,
      "signal_type" => @signal_type,
      "event_type" => @event_type,
      "severity_id" => 1,
      "source" => %{
        "subject" => subject,
        "collector" => "serviceradar_core",
        "system" => "serviceradar"
      },
      "source_identity" => %{
        "table" => table,
        "entity_uid" => uid,
        "entity_type" => entity_type
      },
      "event_identity" => Ecto.UUID.generate(),
      "event_time" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      # Per-node monotonic marker for intra-run ordering. The engine dedupes on
      # event_identity (at-least-once delivery) and uses event_time for a coarse
      # cross-node/restart order.
      "seq" => System.monotonic_time(:nanosecond),
      "routing_correlation" => %{
        "table" => table,
        "record_id" => uid,
        "partition_id" => partition_id,
        "topology_keys" => Enum.reject([table, uid], &is_nil/1)
      },
      "grouped_contexts" => [],
      "signal_domains" => ["data_change"],
      "primary_domain" => "data_change",
      "explainability" =>
        Map.merge(
          %{
            "field" => field,
            "old" => normalize_value(Keyword.get(opts, :old)),
            "new" => normalize_value(Keyword.get(opts, :new)),
            "changed_fields" => if(field, do: [field], else: [])
          },
          stringify_keys(extra)
        ),
      "guardrails" => %{}
    }
  end

  defp encode_and_publish(subject, envelope) do
    with {:ok, json} <- Jason.encode(envelope) do
      Connection.publish(subject, json)
    end
  end

  defp usable_uid?(uid), do: is_binary(uid) and String.trim(uid) != ""

  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify_keys(_), do: %{}
end
