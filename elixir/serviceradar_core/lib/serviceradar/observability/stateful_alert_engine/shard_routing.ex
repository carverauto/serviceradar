defmodule ServiceRadar.Observability.StatefulAlertEngine.ShardRouting do
  @moduledoc """
  Which engine shards own at least one active rule for each signal.

  `StatefulAlertEngine` sends a log, event or metric batch only to the shards
  that own a rule for that signal, instead of to every shard and waiting on the
  slowest. A shard that owns no rule for the signal would match nothing in the
  batch, so skipping it changes no evaluation; it only stops the batch waiting
  on that shard's unrelated work.

  Every call reads the committed active rules from the database, so a rule
  created, updated or deleted on any node — through Ash, a raw writer, or the
  replay `TRUNCATE` — is visible to the next batch on every node. There is no
  node-local cache and nothing to invalidate. A batch that races a rule commit
  may route from the pre-commit set while its shard evaluates the post-commit
  set (or the reverse); each read sees its own snapshot and no batch ever sees
  an older cached generation. When the rules cannot be read (a node without a
  repo), the caller falls back to every shard.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query

  @type signal :: :log | :event | :metric

  @doc """
  The shards owning an active rule for `signal`, or `:all` when the rules
  cannot be read.
  """
  @spec shards_for(signal(), (term() -> non_neg_integer())) ::
          {:ok, [non_neg_integer()]} | :all
  def shards_for(signal, shard_for_rule_id) do
    case read_active_rules() do
      {:ok, rules} ->
        shards =
          rules
          |> Enum.filter(&(&1.signal == signal))
          |> Enum.map(&shard_for_rule_id.(&1.id))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, shards}

      :error ->
        :all
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
