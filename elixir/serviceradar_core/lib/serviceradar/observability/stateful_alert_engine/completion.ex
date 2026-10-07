defmodule ServiceRadar.Observability.StatefulAlertEngine.Completion do
  @moduledoc """
  Bounded completion observation for callers that need persisted effects.

  Normal ingestion does not wait here. The durable receipt, not a process reply
  or a sleep, proves that all rule outcomes for the accepted batch committed.
  """

  alias ServiceRadar.Observability.AlertEvaluationReceipt
  alias ServiceRadar.Observability.StatefulAlertEngine.Inbox
  alias ServiceRadar.Repo

  require Ash.Query

  @poll_ms 25

  def await(keys, timeout_ms) when is_list(keys) and is_integer(timeout_ms) and timeout_ms > 0 do
    await_until(Enum.uniq(keys), System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_until([], _deadline), do: {:ok, []}

  defp await_until(keys, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :evaluation_completion_timeout}
    else
      case Inbox.transact(min(remaining, 2_000), fn -> read_receipts(keys) end) do
        {:ok, receipts} -> observe(keys, receipts, deadline)
        {:error, _} = error -> error
      end
    end
  end

  defp read_receipts(keys) do
    rule_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    source_keys = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    selected = MapSet.new(keys)

    AlertEvaluationReceipt
    |> Ash.Query.filter(rule_id in ^rule_ids and source_key in ^source_keys)
    |> Ash.read!(actor: Inbox.actor())
    |> Enum.filter(&MapSet.member?(selected, {&1.rule_id, &1.source_key}))
  end

  defp observe(keys, receipts, deadline) do
    cond do
      Enum.any?(receipts, &(&1.disposition == :failed)) ->
        {:error, :evaluation_permanently_failed}

      length(receipts) == length(keys) ->
        {:ok, receipts}

      Repo.in_transaction?() ->
        # Uncommitted admission is invisible to another owner. Waiting inside
        # the caller's transaction cannot make it visible and would deadlock.
        {:error, :completion_wait_before_commit}

      true ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        Process.sleep(min(@poll_ms, remaining))
        await_until(keys, deadline)
    end
  end
end
