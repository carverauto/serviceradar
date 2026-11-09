defmodule ServiceRadarWebNG.Edge.DeadLetters do
  @moduledoc """
  Operator access to the edge-record dead-letter stream (`TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`)
  for the Settings -> Cluster "Dead letters" section.

  Every call runs `ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay` on the cluster
  coordinator, a core node: replay republishes to the edge-record subjects, which only the core
  NATS identity may publish to, and web-ng may run without a NATS connection at all.

  A purge deletes the selected dead letters one message at a time. The core identity is denied
  purging the stream itself, and a dead letter is the only copy of its record, so a purge is
  always scoped to what an operator selected and is always audited.

  Each action handles at most 5,000 messages per call. When more matched, the summary says
  so (`complete: false`) and the operator runs it again.
  """

  alias ServiceRadar.Cluster.ClusterStatus
  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay

  require Logger

  @action_limit 5_000
  @inventory_timeout_ms 60_000
  @action_timeout_ms 300_000

  @type group :: %{optional(:contract) => String.t() | nil, optional(:reason) => String.t() | nil}
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
  `nil` for a missing header; an empty map is every held dead letter) and records an audit event
  for `actor`.
  """
  @spec replay(group(), actor()) :: {:ok, summary()} | {:error, term()}
  def replay(group, actor), do: act(:replay, group, actor)

  @doc """
  Deletes the dead letters of `group` (an empty map is every held dead letter) and records an
  audit event for `actor`.
  """
  @spec purge(group(), actor()) :: {:ok, summary()} | {:error, term()}
  def purge(group, actor), do: act(:purge, group, actor)

  @doc """
  What one replay or purge did, from `Replay`'s per-message entries: `done` messages were
  replayed or purged, `kept` were replayed but their dead-letter copy could not be deleted, and
  `failed` are still held with the distinct reasons in `errors`. `error` is set by the caller when
  the run stopped part way.
  """
  @spec summarize(:replay | :purge, [map()], boolean()) :: summary()
  def summarize(action, entries, complete) do
    {done, kept, errors} =
      Enum.reduce(entries, {0, 0, []}, fn
        %{result: result}, {done, kept, errors} when result in [:replayed, :purged] ->
          {done + 1, kept, errors}

        %{result: :replayed_kept}, {done, kept, errors} ->
          {done, kept + 1, errors}

        %{result: {:error, reason}}, {done, kept, errors} ->
          {done, kept, [inspect(reason) | errors]}
      end)

    %{
      action: action,
      done: done,
      kept: kept,
      failed: length(errors),
      errors: errors |> Enum.reverse() |> Enum.uniq(),
      complete: complete,
      error: nil
    }
  end

  defp act(action, group, actor) do
    opts = filters(group) ++ [limit: @action_limit]

    result =
      with {:ok, %{entries: entries, complete: complete} = walk} <-
             call(action, [opts], @action_timeout_ms) do
        {:ok, %{summarize(action, entries, complete) | error: Map.get(walk, :error)}}
      end

    audit(action, group, actor, result)
    result
  end

  @doc """
  The `Replay` filters selecting exactly `group`: a key the group carries as `nil` selects the
  messages lacking that header (`:missing`), and a key it does not carry is not filtered, so `%{}`
  selects every held dead letter.
  """
  @spec filters(group()) :: keyword()
  def filters(group) do
    for key <- [:contract, :reason], Map.has_key?(group, key) do
      {key, Map.get(group, key) || :missing}
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

  defp audit(action, group, actor, result) do
    scope = group |> filters() |> Map.new(fn {k, v} -> {to_string(k), scope_value(v)} end)
    id = Enum.map_join([:contract, :reason], " ", &Map.get(scope, to_string(&1), "*"))

    :ok =
      AuditWriter.write_async(
        action: if(action == :purge, do: :delete, else: :update),
        resource_type: "edge_record_dead_letters",
        resource_id: id,
        resource_name: id,
        actor: actor,
        details: Map.merge(%{"operation" => to_string(action), "scope" => scope}, outcome(result))
      )
  rescue
    error -> Logger.warning("Failed to write dead-letter audit event: #{inspect(error)}")
  end

  defp scope_value(:missing), do: "(missing)"
  defp scope_value(value), do: value

  defp outcome({:ok, summary}) do
    summary
    |> Map.delete(:action)
    |> Map.update!(:error, &(&1 && inspect(&1)))
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp outcome({:error, reason}), do: %{"error" => inspect(reason)}
end
