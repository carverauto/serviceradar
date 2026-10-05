defmodule ServiceRadar.Observability.StatefulAlertEngine.ShardRouting do
  @moduledoc """
  Which engine shards own at least one active rule for each signal.

  `StatefulAlertEngine` sends a log, event or metric batch only to the shards
  that own a rule for that signal, instead of to every shard and waiting on the
  slowest. A shard that owns no rule for the signal would match nothing in the
  batch, so skipping it changes no evaluation; it only stops the batch waiting
  on that shard's unrelated work.

  The map is computed on the calling node from the active rules and cached for
  as long as a shard caches its own rules. It is dropped as soon as a rule is
  created, updated or destroyed on this node, so a new rule is routed to its
  shard as soon as that shard can load it. When the rules cannot be read (a
  node without a repo), the caller falls back to every shard.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query

  @cache_key {__MODULE__, :routing}
  @ttl_ms to_timeout(minute: 1)

  @type signal :: :log | :event | :metric

  @doc """
  The shards, of `shard_count`, owning an active rule for `signal`, or `:all`
  when the rules cannot be read.
  """
  @spec shards_for(signal(), pos_integer(), (term() -> non_neg_integer())) ::
          {:ok, [non_neg_integer()]} | :all
  def shards_for(signal, shard_count, shard_for_rule_id) do
    case routing(shard_count, shard_for_rule_id) do
      {:ok, by_signal} -> {:ok, by_signal |> Map.get(signal, MapSet.new()) |> Enum.sort()}
      :error -> :all
    end
  end

  @doc "Drops this node's cached routing; the next batch recomputes it."
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp routing(shard_count, shard_for_rule_id) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      %{shard_count: ^shard_count, expires_at: expires_at, by_signal: by_signal}
      when expires_at > now ->
        {:ok, by_signal}

      _missing_or_stale ->
        compute(shard_count, shard_for_rule_id, now)
    end
  end

  defp compute(shard_count, shard_for_rule_id, now) do
    case read_active_rules() do
      {:ok, rules} ->
        by_signal =
          Enum.reduce(rules, %{}, fn rule, acc ->
            shard = shard_for_rule_id.(rule.id)
            Map.update(acc, rule.signal, MapSet.new([shard]), &MapSet.put(&1, shard))
          end)

        :persistent_term.put(@cache_key, %{
          shard_count: shard_count,
          expires_at: now + @ttl_ms,
          by_signal: by_signal
        })

        {:ok, by_signal}

      :error ->
        :error
    end
  end

  defp read_active_rules do
    if repo_available?() do
      StatefulAlertRule
      |> Ash.Query.for_read(:active, %{})
      |> Ash.Query.select([:id, :signal])
      |> Ash.read(actor: SystemActor.system(:alert_engine))
      |> case do
        {:ok, %Ash.Page.Keyset{results: results}} -> {:ok, results}
        {:ok, results} when is_list(results) -> {:ok, results}
        {:error, _error} -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp repo_available? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
