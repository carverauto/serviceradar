defmodule ServiceRadarWebNG.Edge.DeadLetters do
  @moduledoc """
  Operator access to the edge-record dead-letter stream (`TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`)
  for the Settings -> Cluster "Dead letters" section.

  Every call runs `ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay` on the cluster
  coordinator, a core node: replay republishes to the edge-record subjects, which only the core
  NATS identity may publish to, and web-ng may run without a NATS connection at all.

  A purge deletes the selected dead letters one message at a time. The core identity is denied
  purging the stream itself, and a dead letter is the only copy of its record, so a purge is
  always scoped to what an operator selected. Every replay and purge is audited on the
  coordinator (`Replay.operator_action/3`), when it starts and when it ends, so the record does
  not depend on the page that asked for it staying open.

  Each action handles at most 5,000 messages per call. When more matched, the summary says
  so (`complete: false`) and the operator runs it again.
  """

  alias ServiceRadar.Cluster.ClusterStatus
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay

  @action_limit 5_000
  @inventory_timeout_ms 60_000
  @action_timeout_ms 300_000

  @type group :: %{
          optional(:contract) => String.t() | nil,
          optional(:reason) => String.t() | nil,
          optional(:through_sequence) => pos_integer() | nil
        }
  @type actor :: %{id: term(), email: term()} | nil
  @type summary :: %{
          action: :replay | :purge,
          done: non_neg_integer(),
          kept: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [String.t()],
          complete: boolean(),
          error: term()
        }

  @doc "The held dead letters grouped by contract and reason (`Replay.inventory/1`)."
  @spec inventory() :: {:ok, map()} | {:error, term()}
  def inventory, do: call(:inventory, [[]], @inventory_timeout_ms)

  @doc """
  Replays the dead letters of `group` (a contract and/or reason as `inventory/0` reports them,
  `nil` for a missing header; an empty map is every held dead letter), up to the inventory's
  `through_sequence` when the group carries one, audited on the coordinator for `actor`.
  """
  @spec replay(group(), actor()) :: {:ok, summary()} | {:error, term()}
  def replay(group, actor), do: act(:replay, group, actor)

  @doc """
  Deletes the dead letters of `group` (an empty map is every held dead letter), bounded like
  `replay/2`, audited on the coordinator for `actor`.
  """
  @spec purge(group(), actor()) :: {:ok, summary()} | {:error, term()}
  def purge(group, actor), do: act(:purge, group, actor)

  @doc """
  What one replay or purge did, for display: `Replay.summarize/1`'s counts of its per-message
  entries, with the action and whether the run covered everything it selected. `error` is set by
  the caller when the run stopped part way.
  """
  @spec summarize(:replay | :purge, [map()], boolean()) :: summary()
  def summarize(action, entries, complete) do
    entries
    |> Replay.summarize()
    |> Map.merge(%{action: action, complete: complete, error: nil})
  end

  defp act(action, group, actor) do
    opts = filters(group) ++ [limit: @action_limit]

    with {:ok, %{entries: entries, complete: complete} = walk} <-
           call(:operator_action, [action, opts, actor], @action_timeout_ms) do
      {:ok, %{summarize(action, entries, complete) | error: Map.get(walk, :error)}}
    end
  end

  @doc """
  The `Replay` filters selecting exactly `group`: a key the group carries as `nil` selects the
  messages lacking that header (`:missing`), and a key it does not carry is not filtered, so `%{}`
  selects every held dead letter. A `through_sequence` stops the walk after that dead-letter
  sequence.
  """
  @spec filters(group()) :: keyword()
  def filters(group) do
    headers = for key <- [:contract, :reason], Map.has_key?(group, key), do: {key, Map.get(group, key) || :missing}

    case Map.get(group, :through_sequence) do
      nil -> headers
      through -> headers ++ [through_sequence: through]
    end
  end

  defp call(fun, args, timeout) do
    case ClusterStatus.find_coordinator() do
      nil ->
        {:error, :no_coordinator}

      node ->
        case :rpc.call(node, Replay, fun, args, timeout) do
          {:ok, _result} = ok -> ok
          {:error, _reason} = error -> error
          {:badrpc, reason} -> {:error, {:badrpc, reason}}
          other -> {:error, {:unexpected_response, other}}
        end
    end
  end
end
