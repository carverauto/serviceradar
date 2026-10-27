defmodule ServiceRadar.Inventory.Availability.Transitions do
  @moduledoc """
  The resolver's transition outbox (`add-merged-device-availability`, design Decision 8).

  `Resolution` inserts one job of this worker, in the resolving transaction, for each
  batch that changed a device row: it commits with the decision and a rollback discards
  it, so nothing is announced for a decision that did not commit. After commit the job:

    * broadcasts a UI invalidation for every changed device (`DevicePubSub`);
    * publishes `signals.state.ocsf_devices` transitions of `availability_state`, and of
      `is_available` where the boolean changed (`StateChangePublisher`, gated by its own
      feed flag, as before);
    * publishes `device.available` and `device.unavailable` on the internal sweep log
      subject the seeded `sweep_device_unavailable` rule matches, only when the
      deployment setting `availability_settings.transition_events` is on and, for a
      transition decided by a sweep group's per-agent rows, only when that group has
      `emit_availability_events` (Open Question 6). A transition to `unknown` has no
      device event.

  Display-only changes (provenance, conflict, agent counters) are carried only for the
  UI invalidation. The resolver is the only emitter of availability transitions.
  """

  use Oban.Worker, queue: :events, max_attempts: 10

  alias ServiceRadar.Events.InternalLogPublisher
  alias ServiceRadar.EventWriter.StateChangePublisher
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Repo

  require Logger

  @ledger_kind "agent_probe"
  @subject "sweep"

  @type transition :: %{
          required(:uid) => String.t(),
          required(:from) => String.t(),
          required(:to) => String.t(),
          required(:available_from) => boolean() | nil,
          required(:available_to) => boolean() | nil,
          required(:decided_by) => map(),
          required(:conflict) => boolean()
        }

  @doc """
  Inserts the outbox job for one resolved batch, in the caller's transaction.
  `transitions` are state changes; `invalidated` are every changed device's uids.
  """
  @spec enqueue([transition()], [String.t()], keyword()) :: :ok
  def enqueue(transitions, invalidated, query_opts \\ [])
  def enqueue([], [], _query_opts), do: :ok

  def enqueue(transitions, invalidated, query_opts) do
    %{"transitions" => Enum.map(transitions, &stringify/1), "invalidated" => invalidated}
    |> new()
    |> Repo.insert!([prefix: "platform"] ++ query_opts)

    :ok
  end

  @doc "Whether the deployment emits `device.*` availability events (opt-in)."
  @spec enabled?() :: boolean()
  def enabled? do
    case Repo.query!(
           "SELECT transition_events FROM platform.availability_settings WHERE singleton"
         ) do
      %{rows: [[true]]} -> true
      _ -> false
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    transitions = Map.get(args, "transitions", [])
    DevicePubSub.broadcast_invalidated(Map.get(args, "invalidated", []))
    Enum.each(transitions, &publish_state_feed/1)

    if transitions != [] and enabled?() do
      transitions
      |> Enum.filter(&(&1["to"] in ["available", "unavailable"]))
      |> filter_by_sweep_group()
      |> publish_device_events()
    end

    :ok
  end

  @doc """
  Publishes the one summary event of the upgrade reconciliation
  (`ServiceRadar.Inventory.Availability.ReconcileWorker`): the number of live devices
  whose merged state differs from their legacy value, per resulting state.
  """
  @spec publish_summary(%{String.t() => non_neg_integer()}) :: :ok
  def publish_summary(counts) do
    available = Map.get(counts, "available", 0)
    unavailable = Map.get(counts, "unavailable", 0)
    unknown = Map.get(counts, "unknown", 0)

    payload = %{
      "event_type" => "availability.reconciliation",
      "severity" => "info",
      "message" =>
        "availability reconciliation: #{available} to available, #{unavailable} to " <>
          "unavailable, #{unknown} to unknown",
      "attributes" => %{
        "event_type" => "availability.reconciliation",
        "to_available" => available,
        "to_unavailable" => unavailable,
        "to_unknown" => unknown
      }
    }

    case InternalLogPublisher.publish("availability", payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("availability reconciliation summary publish failed",
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Publishes a `device.available` recovery event, marked as a reconciliation, for each
  device in `uids`, so an alert opened from the legacy value is closed by the alert
  engine's recovery path.
  """
  @spec publish_reconciled_recoveries([String.t()]) :: :ok
  def publish_reconciled_recoveries(uids) do
    labels = labels(uids)

    Enum.each(uids, fn uid ->
      publish_device_event(
        %{
          "uid" => uid,
          "to" => "available",
          "from" => "unavailable",
          "decided_by" => %{"rule" => "reconciliation"},
          "conflict" => false
        },
        Map.get(labels, uid, %{}),
        "availability_reconciliation"
      )
    end)
  end

  defp publish_state_feed(transition) do
    uid = transition["uid"]
    extra = feed_extra(transition)

    StateChangePublisher.publish_transition("ocsf_devices", uid,
      field: "availability_state",
      old: transition["from"],
      new: transition["to"],
      entity_type: "device",
      extra: extra
    )

    if transition["available_from"] != transition["available_to"] do
      StateChangePublisher.publish_transition("ocsf_devices", uid,
        field: "is_available",
        old: transition["available_from"],
        new: transition["available_to"],
        entity_type: "device",
        extra: extra
      )
    end
  end

  defp feed_extra(transition) do
    decided_by = transition["decided_by"] || %{}

    %{
      "source_kind" => decided_by["source_kind"],
      "authority_class" => decided_by["authority_class"],
      "reporter_agent_id" => decided_by["reporter_agent_id"],
      "previous_state" => transition["from"],
      "conflict" => transition["conflict"]
    }
  end

  # A transition decided by a sweep group's per-agent rows is emitted only when that
  # group opted in; any other transition only needs the deployment setting.
  defp filter_by_sweep_group(transitions) do
    group_ids =
      transitions
      |> Enum.flat_map(fn transition ->
        case sweep_group_id(transition) do
          nil -> []
          id -> [id]
        end
      end)
      |> Enum.uniq()

    emitting = emitting_groups(group_ids)

    Enum.filter(transitions, fn transition ->
      case sweep_group_id(transition) do
        nil -> true
        id -> MapSet.member?(emitting, id)
      end
    end)
  end

  defp sweep_group_id(%{"decided_by" => %{"source_kind" => @ledger_kind} = decided_by}) do
    case decided_by["source_instance"] do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp sweep_group_id(_transition), do: nil

  defp emitting_groups([]), do: MapSet.new()

  defp emitting_groups(ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id::text FROM platform.sweep_groups
        WHERE id::text = ANY($1::text[]) AND emit_availability_events
        """,
        [ids]
      )

    MapSet.new(rows, &hd/1)
  end

  defp publish_device_events([]), do: :ok

  defp publish_device_events(transitions) do
    labels = transitions |> Enum.map(& &1["uid"]) |> labels()

    Enum.each(transitions, fn transition ->
      publish_device_event(transition, Map.get(labels, transition["uid"], %{}), nil)
    end)
  end

  defp publish_device_event(transition, label, reason) do
    uid = transition["uid"]

    event_type =
      if transition["to"] == "available", do: "device.available", else: "device.unavailable"

    decided_by = transition["decided_by"] || %{}
    name = label[:hostname] || label[:ip] || uid

    payload = %{
      "event_type" => event_type,
      "severity" => if(event_type == "device.available", do: "info", else: "warning"),
      "message" => message(event_type, name),
      "device_uid" => uid,
      "attributes" => %{
        "event_type" => event_type,
        "device_uid" => uid,
        "device" => %{"uid" => uid},
        "hostname" => label[:hostname],
        "ip" => label[:ip],
        "source_kind" => decided_by["source_kind"],
        "authority_class" => decided_by["authority_class"],
        "reporter_agent_id" => decided_by["reporter_agent_id"],
        "sweep_group_id" => sweep_group_id(transition),
        "previous_state" => transition["from"],
        "conflict" => transition["conflict"],
        "reason" => reason
      }
    }

    case InternalLogPublisher.publish(@subject, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("availability transition publish failed",
          device_uid: uid,
          event_type: event_type,
          reason: inspect(reason)
        )
    end
  end

  defp message("device.available", name), do: "Device #{name} is available"
  defp message(_event_type, name), do: "Device #{name} is unavailable"

  defp labels([]), do: %{}

  defp labels(uids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT uid, NULLIF(hostname, ''), NULLIF(ip, '') FROM platform.ocsf_devices WHERE uid = ANY($1::text[])",
        [uids]
      )

    Map.new(rows, fn [uid, hostname, ip] -> {uid, %{hostname: hostname, ip: ip}} end)
  end

  defp stringify(transition),
    do: Map.new(transition, fn {key, value} -> {to_string(key), value} end)
end
