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
  node-local cache and nothing to invalidate. A batch uses one committed read
  for both eligibility (which shards own a rule for the signal) and evaluation
  (which rules each owning shard applies): the caller takes a single snapshot
  (`snapshot_for/2`) and hands each owning shard its selected rules, so a rule
  commit racing the batch cannot route from one generation and evaluate from
  another. When the rules cannot be read (a node without a repo), the caller
  falls back to every shard.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query

  @type signal :: :log | :event | :metric

  @doc """
  One committed snapshot for a batch: the shards owning an active rule for
  `signal`, plus the selected full rules for each owning shard.

  The caller passes each shard its own list so routing and evaluation share
  one generation. Returns `:all` when the rules cannot be read.
  """
  @spec snapshot_for(signal(), (term() -> non_neg_integer())) ::
          {:ok, %{shards: [non_neg_integer()], rules_by_shard: %{non_neg_integer() => [term()]}}}
          | :all
  def snapshot_for(signal, shard_for_rule_id) do
    case read_snapshot_rules() do
      {:ok, rules} ->
        rules_by_shard =
          rules
          |> Enum.filter(&(&1.signal == signal))
          |> Enum.group_by(&shard_for_rule_id.(&1.id))

        {:ok,
         %{shards: rules_by_shard |> Map.keys() |> Enum.sort(), rules_by_shard: rules_by_shard}}

      :error ->
        :all
    end
  end

  defp read_snapshot_rules do
    if repo_available?() do
      StatefulAlertRule
      |> Ash.Query.for_read(:active, %{})
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
