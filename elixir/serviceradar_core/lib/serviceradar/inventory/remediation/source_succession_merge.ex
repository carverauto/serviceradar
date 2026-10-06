defmodule ServiceRadar.Inventory.Remediation.SourceSuccessionMerge do
  @moduledoc """
  Step `source-succession`: classes 2, 3, 4 and 6 of the source id remediation (change
  `add-source-id-succession`, design D11), and the count of class 8.

    * Classes 2 and 3, a retired-only predecessor and its successor sharing a universal MAC and
      a hostname (2) or a first-seen time only (3): the step merges each pair with reason
      `source_succession`, as a scheduled run does (`SourceSuccession.merge_pair/3`), and the
      merge guard admits exactly these merges.
    * Classes 4 and 6, weaker evidence and sets that are not one-to-one: the step records their
      review decisions, which open the review tasks, and merges nothing.
    * Class 8, one source id in the metadata of several live records, is reviewed only: the dry
      run counts it (`SourceIdVerification.metadata_duplicates/1`), apart from the values
      `:reviewed_source_ids` names.

  It runs after `source-id-retire`, whose retirements make the predecessors. A scheduled run
  merges at most `max_successions_per_run` pairs; the step merges every pair the plan finds, in
  batches of `:source_batch_size` (500 by default). Each merge writes its manifest entry, the
  merge audit id and the mark the merge cleared from the predecessor, inside the merge
  transaction, and after each batch of merges the harm checks run
  (`SourceIdVerification.finish_batch/4`). The step stops at the first check that fails, and at
  a manifest entry that cannot be written.
  """

  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.SourceSuccession
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.SourceIdVerification

  require Logger

  @step "source-succession"
  @default_batch_size 500
  @sample 20
  # The review reasons of class 6; the others are class 4.
  @class_6_reasons [:not_one_to_one, :shared_mac]
  @pair_fields [:predecessor, :successor, :survivor, :merged, :hostname_shared]

  @doc false
  def run(mode, opts, manifest, actor) do
    case SourceIdVerification.settings(actor) do
      {:ok, settings} -> run(mode, opts, manifest, actor, settings)
      {:error, reason} -> %{errors: 1, error: inspect(reason)}
    end
  end

  defp run(:dry_run, opts, _manifest, actor, settings) do
    %{successive: pairs, reviews: reviews} = SourceSuccession.plan(actor: actor)
    {class_2, class_3} = Enum.split_with(pairs, & &1.hostname_shared)
    {class_6, class_4} = Enum.split_with(reviews, &(&1.reason in @class_6_reasons))

    duplicates =
      SourceIdVerification.metadata_duplicates(Keyword.get(opts, :reviewed_source_ids, []))

    %{
      scheduled_successions_per_run: settings.max_successions_per_run,
      class_2_pairs: length(class_2),
      class_3_pairs: length(class_3),
      class_4_reviews: length(class_4),
      class_6_reviews: length(class_6),
      review_reasons: Enum.frequencies_by(reviews, & &1.reason),
      class_8_groups: duplicates.groups,
      class_8_records: duplicates.records,
      merge_sample: pairs |> Enum.take(@sample) |> Enum.map(&Map.take(&1, @pair_fields)),
      review_sample: reviews |> Enum.take(@sample) |> Enum.map(&review_entry/1),
      class_8_sample: duplicates.sample
    }
  end

  defp run(:execute, opts, manifest, actor, settings) do
    case Manifest.ensure_writable(manifest) do
      :ok ->
        execute(opts, manifest, actor, settings)

      {:error, reason} ->
        %{manifest_failures: 1, halted: "manifest", error: inspect(reason)}
    end
  end

  defp execute(opts, manifest, actor, settings) do
    run = %{
      manifest: manifest,
      actor: actor,
      settings: settings,
      batch_size: Keyword.get(opts, :source_batch_size, @default_batch_size),
      manifest_errors: :counters.new(1, [])
    }

    %{successive: pairs, reviews: reviews} = SourceSuccession.plan(actor: actor)

    state =
      reviews
      |> Enum.chunk_every(run.batch_size)
      |> Enum.reduce_while(initial_state(settings), &review_batch(&1, &2, run))

    state =
      if state.halted do
        state
      else
        pairs
        |> Enum.chunk_every(run.batch_size)
        |> Enum.reduce_while(state, &merge_batch(&1, &2, run))
      end

    if state.halted, do: state, else: Map.delete(state, :halted)
  end

  defp initial_state(settings) do
    %{
      scheduled_successions_per_run: settings.max_successions_per_run,
      merged: 0,
      merge_blocked: 0,
      stale: 0,
      merge_failures: 0,
      manifest_failures: 0,
      reviews_recorded: 0,
      review_failures: 0,
      batches: 0,
      harm_check_failures: 0,
      checks: [],
      halted: nil
    }
  end

  # Reviews change no record, so no check runs after them. They are not rolled back: a review
  # task an operator does not need is closed as such.
  defp review_batch(reviews, state, run) do
    case DecisionLog.record_many_strict(Enum.map(reviews, & &1.decision)) do
      :ok ->
        entry = %{reviews: Enum.map(reviews, &review_entry/1)}

        case record(run, "record_reviews", "platform.identity_decisions", [], entry) do
          :ok ->
            {:cont, %{state | reviews_recorded: state.reviews_recorded + length(reviews)}}

          {:error, _reason} ->
            {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}
        end

      other ->
        Logger.warning(
          "#{@step}: could not record #{length(reviews)} review(s): #{inspect(other)}"
        )

        {:cont, %{state | review_failures: state.review_failures + length(reviews)}}
    end
  end

  defp review_entry(review), do: %{reason: review.reason, device_uids: review.device_uids}

  # The merge runs in an Ash transaction, which returns an error as an Ash error, so a manifest
  # entry that could not be written is told from other failures by the counter `record/5` bumps.
  defp merge_batch(pairs, state, run) do
    state =
      pairs
      |> SourceSuccession.with_collections()
      |> Enum.reduce_while(state, fn pair, state ->
        pair = put_in(pair, [:evidence, "source"], "dire_remediation")
        before = :counters.get(run.manifest_errors, 1)

        result =
          SourceSuccession.merge_pair(pair, run.actor, on_merged: &record_merge(&1, pair, run))

        cond do
          :counters.get(run.manifest_errors, 1) > before ->
            {:halt, %{state | manifest_failures: state.manifest_failures + 1, halted: "manifest"}}

          result == :ok ->
            {:cont, %{state | merged: state.merged + 1}}

          match?({:error, :merge_blocked, _error}, result) ->
            {:cont, %{state | merge_blocked: state.merge_blocked + 1}}

          match?({:error, :stale, _error}, result) ->
            {:cont, %{state | stale: state.stale + 1}}

          true ->
            {:cont, %{state | merge_failures: state.merge_failures + 1}}
        end
      end)

    state = if state.halted, do: state, else: finish_batch(state, run)
    if state.halted, do: {:halt, state}, else: {:cont, state}
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

  # Called inside the merge transaction, under its locks: the merge audit records the mark the
  # merge cleared from the predecessor, which the rollback sets again after the unmerge.
  defp record_merge(%MergeAudit{} = audit, pair, run) do
    record(run, "succession_merge", "platform.merge_audit", [audit.event_id], %{
      merged: pair.merged,
      survivor: pair.survivor,
      predecessor: pair.predecessor,
      successor: pair.successor,
      predecessor_source_retired_at: predecessor_mark(audit.details)
    })
  end

  defp predecessor_mark(%{"succession" => %{"predecessor_source_retired_at" => at}}), do: at
  defp predecessor_mark(_details), do: nil

  defp record(run, action, table, ids, extra) do
    case Manifest.record(run.manifest, @step, action, table, ids, extra) do
      :ok ->
        :ok

      {:error, reason} ->
        :counters.add(run.manifest_errors, 1, 1)
        Logger.error("#{@step}: failed to record #{action} in the manifest: #{inspect(reason)}")
        {:error, {:manifest_failed, reason}}
    end
  end
end
