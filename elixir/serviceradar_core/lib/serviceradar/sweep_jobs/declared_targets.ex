defmodule ServiceRadar.SweepJobs.DeclaredTargets do
  @moduledoc """
  Records the device targets each sweep group's target query declared, in
  `platform.sweep_group_declared_targets`, so `platform.device_sweep_overlap`
  can compare declared targets with observed coverage.

  `SweepCompiler.compile/3` calls `record/1` with the target sets it just
  compiled into an agent's config, so the recorded declaration is what agents
  actually received, not a separate re-resolution. It is stored once per
  group: a group's device targets do not depend on which agent compiles it,
  and the view derives the agent from the group's `agent_ids`.

  Writes are cheap when nothing changed and safe when many agents compile the
  same group at once:

    * a digest of the last recorded set per group, kept under the `:sweep`
      config type, skips the database entirely while the set is unchanged;
    * a changed set is written in one transaction that first takes a
      per-group transaction advisory lock with `pg_try_advisory_xact_lock`.
      A compile that finds the lock taken skips the write, because another
      compile of the same group is recording the same shared query result
      right now; its digest is not stored, so the next compile checks again;
    * a group whose query did not resolve is not passed in, so its last
      recorded set is kept rather than replaced with nothing.

  Recording never fails a compile: errors are logged and swallowed.
  """

  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.Repo

  require Logger

  @digest_partition "__sweep_declared_targets__"

  # Two-key advisory lock namespace, so these locks cannot collide with any
  # single-key advisory lock taken elsewhere.
  @lock_class "sweep_group_declared_targets"

  @type pair :: {String.t(), String.t() | nil}
  @type plan :: %{upsert: [pair()], delete: [String.t()]}

  @doc """
  Records each group's declared target pairs, keyed by sweep group id.
  """
  @spec record(%{optional(String.t()) => [pair()]}) :: :ok
  def record(declarations) when is_map(declarations) do
    Enum.each(declarations, fn {sweep_group_id, pairs} -> record_group(sweep_group_id, pairs) end)
  end

  @doc false
  # The rows to write so a group's recorded declaration equals `declared`,
  # touching only what changed: unchanged rows keep their resolved_at.
  @spec plan_changes([pair()], [pair()]) :: plan()
  def plan_changes(current, declared) do
    current_map = Map.new(current)
    declared_map = Map.new(declared)

    upsert =
      declared_map
      |> Enum.reject(fn {target, uid} -> Map.fetch(current_map, target) == {:ok, uid} end)
      |> Enum.sort()

    delete =
      current_map
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(declared_map, &1))
      |> Enum.sort()

    %{upsert: upsert, delete: delete}
  end

  defp record_group(sweep_group_id, pairs) do
    pairs = Enum.sort(pairs)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(pairs))
    scope = {:sweep_declared_digest, sweep_group_id}

    case ConfigCache.get(:sweep, @digest_partition, nil, scope) do
      {:ok, %{digest: ^digest}} ->
        :ok

      _ ->
        if write(sweep_group_id, pairs) == :written do
          ConfigCache.put(:sweep, @digest_partition, nil, %{digest: digest}, scope)
        end

        :ok
    end
  end

  defp write(sweep_group_id, pairs) do
    result =
      Repo.transaction(fn ->
        if lock_group(sweep_group_id) do
          current = current_rows(sweep_group_id)
          apply_plan(sweep_group_id, plan_changes(current, pairs))
          :written
        else
          :busy
        end
      end)

    case result do
      {:ok, outcome} ->
        outcome

      {:error, reason} ->
        log_error(sweep_group_id, reason)
        :failed
    end
  rescue
    error ->
      log_error(sweep_group_id, error)
      :failed
  end

  defp lock_group(sweep_group_id) do
    %{rows: [[locked?]]} =
      Repo.query!(
        "SELECT pg_try_advisory_xact_lock(hashtext(CAST($1 AS text)), hashtext(CAST($2 AS text)))",
        [@lock_class, sweep_group_id]
      )

    locked?
  end

  defp current_rows(sweep_group_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT target, device_uid
        FROM platform.sweep_group_declared_targets
        WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid)
        """,
        [sweep_group_id]
      )

    Enum.map(rows, fn [target, uid] -> {target, uid} end)
  end

  defp apply_plan(_sweep_group_id, %{upsert: [], delete: []}), do: :ok

  defp apply_plan(sweep_group_id, %{upsert: upsert, delete: delete}) do
    if delete != [] do
      Repo.query!(
        """
        DELETE FROM platform.sweep_group_declared_targets
        WHERE sweep_group_id = CAST(CAST($1 AS text) AS uuid) AND target = ANY(CAST($2 AS text[]))
        """,
        [sweep_group_id, delete]
      )
    end

    if upsert != [] do
      {targets, uids} = Enum.unzip(upsert)

      Repo.query!(
        """
        INSERT INTO platform.sweep_group_declared_targets
          (sweep_group_id, target, device_uid, resolved_at)
        SELECT CAST(CAST($1 AS text) AS uuid), t.target, t.device_uid, now()
        FROM unnest(CAST($2 AS text[]), CAST($3 AS text[])) AS t(target, device_uid)
        ON CONFLICT (sweep_group_id, target) DO UPDATE
          SET device_uid = EXCLUDED.device_uid, resolved_at = EXCLUDED.resolved_at
        """,
        [sweep_group_id, targets, uids]
      )
    end

    :ok
  end

  defp log_error(sweep_group_id, reason) do
    Logger.error(
      "SweepDeclaredTargets: failed to record targets for group #{inspect(sweep_group_id)}: " <>
        inspect(reason)
    )
  end
end
