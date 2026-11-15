defmodule ServiceRadar.Inventory.Availability.History do
  @moduledoc """
  The append-only history of merged device availability
  (`fix-device-availability-timeline`, design Decision 2).

  Every change of a device's merged `availability_state` becomes one record on
  `availability.transitions.device`, published through JetStream
  (`ServiceRadar.NATS.DurablePublish`) and stored by
  `ServiceRadar.EventWriter.Processors.AvailabilityTransitions`: in StarRocks when it is
  enabled, in CNPG otherwise. Core never writes the history to a database itself.

  A record closes one interval of the device's history: the device was `from_state` from
  `from_since` (the previous `availability_changed_at`, absent when the device had no
  decision) until `changed_at`, when it became `to_state`. The device row's current state
  covers the time since its last change. History is therefore rebuilt from the records
  alone, with no lookback past a window, and a lost record leaves a gap that reads as
  unknown.

  Recording is not gated by the opt-in `device.*` availability events, and includes the
  changes the upgrade reconciliation writes, whose events stay suppressed. The message id
  is derived from the device, the decision time and the new state, so a republish is
  stored once.
  """

  alias ServiceRadar.NATS.DurablePublish

  @subject "availability.transitions.device"

  @type record :: %{required(String.t()) => term()}

  @doc "The JetStream subject the history is published on."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  Builds the history record of one transition, as `ServiceRadar.Inventory.Availability.Transitions`
  carries it (string keys): `uid`, `from`, `to`, `from_since`, `changed_at`, `decided_by` and
  `conflict`.
  """
  @spec record(map()) :: record()
  def record(%{"uid" => uid, "from" => from, "to" => to} = transition) do
    decided_by = transition["decided_by"] || %{}

    %{
      "device_uid" => uid,
      "from_state" => from,
      "from_since" => transition["from_since"],
      "to_state" => to,
      "changed_at" => transition["changed_at"],
      "authority_class" => decided_by["authority_class"],
      "source_kind" => decided_by["source_kind"],
      "reporter_agent_id" => decided_by["reporter_agent_id"],
      "rule" => decided_by["rule"],
      "conflict" => transition["conflict"] == true
    }
  end

  @doc "The stable message id of a history record."
  @spec msg_id(record()) :: String.t()
  def msg_id(%{"device_uid" => uid, "changed_at" => changed_at, "to_state" => to}) do
    digest =
      :sha256
      |> :crypto.hash(Enum.join([uid, changed_at, to], "\u0000"))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "availability-transition:" <> digest
  end

  @doc """
  Publishes the history records of `transitions`. Returns `:ok` once each is stored in
  JetStream or queued for a durable retry, and the first `{:error, reason}` otherwise.
  `opts` pass through to `ServiceRadar.NATS.DurablePublish.publish/3`.
  """
  @spec publish([map()], keyword()) :: :ok | {:error, term()}
  def publish(transitions, opts \\ []) do
    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      record = record(transition)

      case DurablePublish.publish(
             @subject,
             Jason.encode!(record),
             [msg_id: msg_id(record)] ++ opts
           ) do
        :ok -> {:cont, :ok}
        {:ok, :enqueued} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
