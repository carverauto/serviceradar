defmodule ServiceRadar.Inventory.Remediation.ReleasedSeedShells do
  @moduledoc """
  Step `released-seed-shells`: class 7 of the source id remediation (change
  `add-source-id-succession`, design D11).

  A released-seed shell is a live sweep-only record that gave up its address and holds no
  identifier, current or archived, and no other address
  (`PopulationGauges.released_seed_shell/0`). A seed that releases its address is soft-deleted
  in the same transaction since design D8; the step soft-deletes the shells an earlier release
  left, with the reason `seed_released`, a retained tombstone no sweep or sync revives. A shell
  held for review stays.

  The dry run counts them. `--execute` works in batches of `:source_batch_size` (500 by
  default), each one transaction that locks the records, reads the condition again under the
  locks, soft-deletes them and writes the manifest entry. The harm checks run after each batch
  (`SourceIdVerification.finish_batch/4`), and the step stops at the first that fails.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.PopulationGauges
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.SourceIdVerification
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "released-seed-shells"
  @default_batch_size 500
  @sample 20
  @deleted_reason "seed_released"
  @deleted_by "system:dire_remediation"

  # FOR UPDATE, not FOR NO KEY UPDATE: an identifier insert of any type takes FOR KEY SHARE on
  # its record through the foreign key, so it waits for the batch or the batch waits for it,
  # and the condition read again under the lock sees an identifier committed first. The
  # identifier-owner advisory lock covers Armis and NetBox ids only.
  @lock_sql """
  SELECT d.uid FROM platform.ocsf_devices AS d
  WHERE d.uid = ANY (CAST($1 AS text[])) AND d.deleted_at IS NULL
  ORDER BY d.uid
  FOR UPDATE
  """

  @doc false
  def run(mode, opts, manifest, actor) do
    case SourceIdVerification.settings(actor) do
      {:ok, settings} -> run(mode, opts, manifest, actor, settings)
      {:error, reason} -> %{errors: 1, error: inspect(reason)}
    end
  end

  defp run(:dry_run, _opts, _manifest, _actor, _settings) do
    {count, sample} = SourceIdVerification.released_seed_shells(@sample)
    %{class_7_shells: count, class_7_sample: sample}
  end

  defp run(:execute, opts, manifest, actor, settings) do
    case Manifest.ensure_writable(manifest) do
      :ok ->
        run = %{
          manifest: manifest,
          actor: actor,
          settings: settings,
          batch_size: Keyword.get(opts, :source_batch_size, @default_batch_size),
          manifest_errors: :counters.new(1, [])
        }

        state = tombstone_after("", initial_state(), run)
        {left, _sample} = SourceIdVerification.released_seed_shells(1)
        state = Map.put(state, :shells_left, left)
        if state.halted, do: state, else: Map.delete(state, :halted)

      {:error, reason} ->
        %{manifest_failures: 1, halted: "manifest", error: inspect(reason)}
    end
  end

  defp initial_state do
    %{
      tombstoned: 0,
      tombstone_failures: 0,
      manifest_failures: 0,
      batches: 0,
      harm_check_failures: 0,
      checks: [],
      halted: nil
    }
  end

  # Keyset over the uids, so a shell held for review is read once.
  defp tombstone_after(cursor, state, run) do
    case shells(cursor, run.batch_size) do
      [] ->
        state

      uids ->
        state = tombstone_batch(uids, state, run)
        if state.halted, do: state, else: tombstone_after(List.last(uids), state, run)
    end
  end

  defp shells(cursor, limit) do
    %{rows: rows} =
      Repo.query!(
        "SELECT d.uid FROM platform.ocsf_devices AS d WHERE " <>
          PopulationGauges.released_seed_shell() <> " AND d.uid > $1 ORDER BY d.uid LIMIT $2",
        [cursor, limit]
      )

    List.flatten(rows)
  end

  defp shells_of(uids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT d.uid FROM platform.ocsf_devices AS d WHERE d.uid = ANY (CAST($1 AS text[])) AND " <>
          PopulationGauges.released_seed_shell() <> " ORDER BY d.uid",
        [uids]
      )

    List.flatten(rows)
  end

  # Ash.transact/3 returns an error as an Ash error, so a manifest entry that could not be
  # written is told from other failures by the counter `record/2` bumps.
  defp tombstone_batch(uids, state, run) do
    before = :counters.get(run.manifest_errors, 1)

    result =
      Ash.transact(Device, fn ->
        _ = Repo.query!(@lock_sql, [uids])

        with [_ | _] = shells <- shells_of(uids),
             {:ok, %{uids: [_ | _]} = deleted} <- soft_delete(shells, run.actor),
             :ok <- record(run, deleted) do
          {:ok, length(deleted.uids)}
        else
          [] -> {:ok, 0}
          {:ok, %{uids: []}} -> {:ok, 0}
          {:error, _} = error -> error
        end
      end)

    state =
      if :counters.get(run.manifest_errors, 1) > before do
        %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}
      else
        case result do
          {:ok, {:ok, count}} ->
            %{state | tombstoned: state.tombstoned + count}

          {:error, error} ->
            Logger.warning(
              "#{@step}: could not soft-delete #{length(uids)} shell(s): #{inspect(error)}"
            )

            %{state | tombstone_failures: state.tombstone_failures + length(uids)}
        end
      end

    if state.halted, do: state, else: finish_batch(state, run)
  end

  # The statement checks liveness and the review hold again, as the grace delete does.
  defp soft_delete(uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter(
      uid in ^uids and is_nil(deleted_at) and
        not fragment("platform.device_held_for_review(?)", uid)
    )
    |> Ash.bulk_update(
      :soft_delete,
      %{deleted_reason: @deleted_reason, deleted_by: @deleted_by},
      actor: actor,
      strategy: [:atomic],
      return_records?: true,
      return_errors?: true,
      select: [:uid, :deleted_at]
    )
    |> case do
      %Ash.BulkResult{status: :success, records: records} ->
        records = List.wrap(records)

        {:ok,
         %{
           uids: records |> Enum.map(& &1.uid) |> Enum.sort(),
           deleted_at: records |> Enum.map(&DateTime.to_iso8601(&1.deleted_at)) |> Enum.uniq()
         }}

      %Ash.BulkResult{errors: errors} ->
        {:error, {:soft_delete_failed, errors}}
    end
  end

  # The tombstones' `deleted_at`, so that the rollback restores these tombstones and not a later
  # run's of the same records.
  defp record(run, deleted) do
    case Manifest.record(
           run.manifest,
           @step,
           "tombstone_shells",
           "platform.ocsf_devices",
           deleted.uids,
           %{
             deleted_reason: @deleted_reason,
             deleted_by: @deleted_by,
             deleted_at: deleted.deleted_at
           }
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)

        Logger.error(
          "#{@step}: failed to record tombstone_shells in the manifest: #{inspect(reason)}"
        )

        {:error, {:manifest_failed, reason}}
    end
  end

  defp finish_batch(state, run) do
    batch = state.batches + 1

    case SourceIdVerification.finish_batch(run.manifest, @step, batch, run.settings) do
      {:ok, checks} ->
        %{state | batches: batch, checks: checks}

      {:halt, check, checks} ->
        Logger.error("#{@step}: check #{check} failed after batch #{batch}; stopping")

        %{
          state
          | batches: batch,
            checks: checks,
            halted: check,
            harm_check_failures: state.harm_check_failures + 1
        }

      {:error, reason} ->
        Logger.error("#{@step}: batch #{batch} could not be recorded: #{inspect(reason)}")

        %{
          state
          | batches: batch,
            manifest_failures: state.manifest_failures + 1,
            halted: "manifest"
        }
    end
  end
end
