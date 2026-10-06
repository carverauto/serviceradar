defmodule ServiceRadar.Inventory.Remediation.SourceIdRollback do
  @moduledoc """
  Step `source-id-rollback`: reverses the source id remediation steps (change
  `add-source-id-succession`, design D11) from the manifests `:rollback_manifests` names. It
  runs alone and only when named. The newest manifest goes first, each manifest's entries in
  reverse order:

    * `tombstone_shells` (`released-seed-shells`): restores each shell the entry soft-deleted,
      while it is still that tombstone, with the entry's reason, actor and `deleted_at`;
    * `succession_merge` (`source-succession`): reverses the merge the entry names by its
      audit id (`MergeEngine.unmerge_device/2` with `:event_id`), then marks the predecessor
      `source_retired` again as of the mark the merge cleared;
    * `mark_source_retired` (`source-id-retire`, class 5): clears the mark unless the record
      changed since (`SourceRetirement.clear_mark/3`);
    * `retire_source_ids` (`source-id-retire`): returns the retired ids to their record
      (`SourceReactivation.unarchive/2`) and, when the retirement marked the record, puts back
      the identity state the mark replaced.

  Each action reads the state it reverses first. A replayed rollback does nothing, and a
  record that changed since is left as it is and counted in `skipped`, by reason. The review
  decisions (`record_reviews`) are not rolled back: an operator closes a review task that is
  not needed. Entries of other steps are ignored.

  The restores and the unmerges run in a transaction whose `application_name` is
  `SourceIdVerification.rollback_application/0`. The revival audit records it, and V6 does not
  count those revivals. The dry run counts what the entries name. `--execute` writes what it
  reversed to its own manifest, and stops at an entry that cannot be written.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.SourceReactivation
  alias ServiceRadar.Inventory.Identity.SourceRetirement
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.SourceIdVerification
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "source-id-rollback"
  @steps ["source-id-retire", "source-succession", "released-seed-shells"]
  @shell_reason "seed_released"
  @shell_actor "system:dire_remediation"
  @unmerged_by "dire_remediation"
  @decision_source "dire_remediation"
  # The refusals of an unmerge of a named merge: reversed already, merged again since, or no
  # longer the merge's tombstone.
  @unmerge_skips [:no_merge_audit_found, :already_unmerged, :merge_superseded, :not_merged]

  @doc false
  def run(mode, opts, manifest, actor) do
    case load(Keyword.get(opts, :rollback_manifests, [])) do
      {:ok, manifests, entries} -> rollback(mode, manifests, entries, manifest, actor)
      {:error, reason} -> %{errors: 1, error: inspect(reason)}
    end
  end

  # The entries of every manifest, the newest manifest first and each one's in reverse.
  defp load([]), do: {:error, :rollback_manifest_required}

  defp load(paths) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, loaded} ->
      with {:ok, header, entries} <- Manifest.read(path),
           {:ok, started_at} <- Manifest.started_at(header) do
        {:cont, {:ok, [{started_at, entries} | loaded]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, loaded} ->
        entries =
          loaded
          |> Enum.sort_by(&elem(&1, 0), {:desc, DateTime})
          |> Enum.flat_map(fn {_started_at, entries} -> Enum.reverse(entries) end)

        {:ok, length(loaded), entries}

      {:error, _} = error ->
        error
    end
  end

  defp action(%{"step" => step, "action" => "batch_finished"}) when step in @steps, do: :marker

  defp action(%{"step" => "released-seed-shells", "action" => "tombstone_shells"}),
    do: :tombstone_shells

  defp action(%{"step" => "source-succession", "action" => "succession_merge"}),
    do: :succession_merge

  defp action(%{"step" => "source-id-retire", "action" => "mark_source_retired"}),
    do: :mark_source_retired

  defp action(%{"step" => "source-id-retire", "action" => "retire_source_ids"}),
    do: :retire_source_ids

  defp action(%{"step" => step}) when step in @steps, do: :not_rolled_back
  defp action(_entry), do: :ignored

  defp rollback(:dry_run, manifests, entries, _manifest, _actor) do
    initial = %{
      manifests: manifests,
      would_restore_shells: 0,
      would_unmerge: 0,
      would_restore_marks: 0,
      would_clear_marks: 0,
      would_return_ids: 0,
      not_rolled_back: 0,
      ignored_entries: 0
    }

    Enum.reduce(entries, initial, fn entry, report ->
      case action(entry) do
        :tombstone_shells ->
          Map.update!(report, :would_restore_shells, &(&1 + length(ids(entry))))

        :succession_merge ->
          marks = if is_binary(entry["predecessor_source_retired_at"]), do: 1, else: 0

          %{
            report
            | would_unmerge: report.would_unmerge + 1,
              would_restore_marks: report.would_restore_marks + marks
          }

        :mark_source_retired ->
          Map.update!(report, :would_clear_marks, &(&1 + 1))

        :retire_source_ids ->
          Map.update!(report, :would_return_ids, &(&1 + length(entry["primary_ids"] || [])))

        :marker ->
          report

        :not_rolled_back ->
          Map.update!(report, :not_rolled_back, &(&1 + 1))

        :ignored ->
          Map.update!(report, :ignored_entries, &(&1 + 1))
      end
    end)
  end

  defp rollback(:execute, manifests, entries, manifest, actor) do
    case Manifest.ensure_writable(manifest) do
      :ok ->
        entries
        |> Enum.reduce_while(initial_state(manifests), &undo_entry(&1, &2, manifest, actor))
        |> then(&if(&1.halted, do: &1, else: Map.delete(&1, :halted)))

      {:error, reason} ->
        %{manifest_failures: 1, halted: "manifest", error: inspect(reason)}
    end
  end

  defp initial_state(manifests) do
    %{
      manifests: manifests,
      shells_restored: 0,
      unmerged: 0,
      marks_restored: 0,
      marks_cleared: 0,
      ids_returned: 0,
      identity_states_restored: 0,
      skipped: 0,
      skip_reasons: %{},
      not_rolled_back: 0,
      ignored_entries: 0,
      rollback_failures: 0,
      manifest_failures: 0,
      halted: nil
    }
  end

  defp undo_entry(entry, state, manifest, actor) do
    case action(entry) do
      :marker ->
        {:cont, state}

      :not_rolled_back ->
        {:cont, Map.update!(state, :not_rolled_back, &(&1 + 1))}

      :ignored ->
        {:cont, Map.update!(state, :ignored_entries, &(&1 + 1))}

      action ->
        case safely(fn -> undo(action, entry, actor) end) do
          {:ok, outcome} ->
            state = tally(state, outcome)
            record(state, manifest, action, entry, outcome)

          {:error, error} ->
            Logger.warning(
              "#{@step}: could not roll back #{action} of #{inspect(ids(entry))}: " <>
                inspect(error, limit: 10)
            )

            {:cont, Map.update!(state, :rollback_failures, &(&1 + 1))}
        end
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  defp undo(:tombstone_shells, entry, actor) do
    uids = ids(entry)
    deleted_at = entry |> Map.get("deleted_at", []) |> Enum.flat_map(&datetime/1)

    in_rollback(fn ->
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(
        uid in ^uids and deleted_reason == ^@shell_reason and deleted_by == ^@shell_actor and
          deleted_at in ^deleted_at
      )
      |> Ash.bulk_update(:restore, %{allow_retained: true},
        actor: actor,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic, :stream]
      )
      |> case do
        %Ash.BulkResult{status: :success, records: records} ->
          restored = records |> List.wrap() |> Enum.map(& &1.uid) |> Enum.sort()
          {:ok, {:shells_restored, restored, length(uids) - length(restored)}}

        %Ash.BulkResult{errors: errors} ->
          {:error, {:restore_failed, errors}}
      end
    end)
  end

  defp undo(:succession_merge, entry, actor) do
    in_rollback(fn ->
      case MergeEngine.unmerge_device(entry["merged"],
             actor: actor,
             unmerged_by: @unmerged_by,
             event_id: List.first(ids(entry))
           ) do
        :ok ->
          case restore_predecessor_mark(entry, actor) do
            {:ok, _} = ok -> ok
            {:error, _} = error -> {:refused, error}
          end

        {:error, reason} when reason in @unmerge_skips -> {:ok, {:skipped, reason}}
        {:error, _} = error -> error
      end
    end)
  end

  defp undo(:mark_source_retired, entry, _actor) do
    with [uid] <- ids(entry),
         [marked_at] <- naive(entry["marked_at"]) do
      if SourceRetirement.clear_mark(uid, marked_at, entry["prior_identity_state"]),
        do: {:ok, :mark_cleared},
        else: {:ok, {:skipped, :mark_changed}}
    else
      _invalid -> {:error, :invalid_entry}
    end
  end

  defp undo(:retire_source_ids, entry, actor) do
    results =
      SourceReactivation.unarchive(entry["primary_ids"] || [],
        actor: actor,
        source: @decision_source
      )

    returned = for {_id, {:ok, holder}} <- results, do: holder
    skipped = for {_id, {:skipped, reason}} <- results, do: reason

    case for({id, {:error, error}} <- results, do: {id, error}) do
      [] ->
        {:ok, {:ids_returned, length(returned), skipped, restore_identity_state(entry, returned)}}

      errors ->
        {:error, {:unarchive_failed, errors}}
    end
  end

  # The merge cleared the predecessor's mark; once it is unmerged, the record is retired-only
  # again and gets the mark back, unless an identity-bearing observation reached it since.
  defp restore_predecessor_mark(%{"predecessor_source_retired_at" => at} = entry, actor)
       when is_binary(at) do
    with [marked_at] <- naive(at),
         {:ok, restored} <- SourceRetirement.restore_mark(entry["predecessor"], marked_at, actor) do
      {:ok, {:unmerged, restored}}
    else
      [] -> {:error, :invalid_entry}
      {:error, _} = error -> error
    end
  end

  defp restore_predecessor_mark(_entry, _actor), do: {:ok, {:unmerged, false}}

  # A retirement that marked the record replaced its identity state; the returned id cleared
  # the mark, and the state the mark replaced is put back.
  defp restore_identity_state(%{"marked" => true, "device_id" => uid} = entry, returned) do
    prior = entry["prior_identity_state"]

    is_binary(prior) and uid in returned and
      SourceRetirement.restore_identity_state(uid, prior)
  end

  defp restore_identity_state(_entry, _returned), do: false

  # One transaction per entry, which names the rollback to the revival audit. An outcome is a
  # value: an error returned through Ash.transact/3 arrives as an Ash error, and a refusal of a
  # nested transaction (the unmerge's) arrives so, without a reason.
  defp in_rollback(fun) do
    Device
    |> Ash.transact(fn ->
      _ =
        Repo.query!("SELECT set_config('application_name', $1, true)", [
          SourceIdVerification.rollback_application()
        ])

      fun.()
    end)
    |> case do
      {:ok, {:ok, outcome}} -> {:ok, outcome}
      {:ok, {:refused, {:error, _} = error}} -> error
      {:error, _} = error -> error
    end
  end

  defp tally(state, {:shells_restored, restored, left}) do
    state
    |> Map.update!(:shells_restored, &(&1 + length(restored)))
    |> skip(:shell_changed, left)
  end

  defp tally(state, {:unmerged, marked}) do
    state = Map.update!(state, :unmerged, &(&1 + 1))
    if marked, do: Map.update!(state, :marks_restored, &(&1 + 1)), else: state
  end

  defp tally(state, :mark_cleared), do: Map.update!(state, :marks_cleared, &(&1 + 1))

  defp tally(state, {:ids_returned, returned, skipped, restored_state}) do
    state =
      state
      |> Map.update!(:ids_returned, &(&1 + returned))
      |> Map.update!(:identity_states_restored, &(&1 + if(restored_state, do: 1, else: 0)))

    Enum.reduce(skipped, state, &skip(&2, &1, 1))
  end

  defp tally(state, {:skipped, reason}), do: skip(state, reason, 1)

  defp skip(state, _reason, 0), do: state

  defp skip(state, reason, count) do
    %{
      state
      | skipped: state.skipped + count,
        skip_reasons: Map.update(state.skip_reasons, reason, count, &(&1 + count))
    }
  end

  defp record(state, manifest, action, entry, outcome) do
    case Manifest.record(manifest, @step, "undo_#{action}", entry["table"], ids(entry), %{
           entry_at: entry["at"],
           entry_step: entry["step"],
           outcome: describe(outcome)
         }) do
      :ok ->
        {:cont, state}

      {:error, reason} ->
        Logger.error(
          "#{@step}: failed to record undo_#{action} in the manifest: #{inspect(reason)}"
        )

        {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
    end
  end

  defp describe({:shells_restored, restored, left}), do: %{restored: restored, left: left}
  defp describe({:unmerged, marked}), do: %{unmerged: true, mark_restored: marked}
  defp describe(:mark_cleared), do: %{mark_cleared: true}

  defp describe({:ids_returned, returned, skipped, restored_state}),
    do: %{returned: returned, skipped: skipped, identity_state_restored: restored_state}

  defp describe({:skipped, reason}), do: %{skipped: reason}

  defp ids(entry) do
    case entry["ids"] do
      ids when is_list(ids) -> ids
      _other -> []
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> [at]
      {:error, _reason} -> []
    end
  end

  defp datetime(_value), do: []

  # The marks are recorded as naive UTC, the merge audit's as UTC with an offset.
  defp naive(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        [DateTime.to_naive(at)]

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, at} -> [at]
          {:error, _reason} -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp naive(_value), do: []
end
