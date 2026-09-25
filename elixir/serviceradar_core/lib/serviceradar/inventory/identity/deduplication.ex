defmodule ServiceRadar.Inventory.Identity.Deduplication do
  @moduledoc """
  De-duplication tasks: the IRE-style third outcome for a suspected duplicate (#4604).

  When DIRE cannot decide -- a merge blocked by `MergePolicy` or a `MergeEngine` guard, a
  source-authority conflict, an IP alias invalidated between two identified devices, an
  active-IP conflict, a source-authoritative override, an ambiguous duplicate component -- it
  records an identity decision (`ServiceRadar.Inventory.IdentityDecision`) and, through
  `open_for_decisions/1`, opens or updates the one `ServiceRadar.Inventory.DeduplicationTask`
  for that device set. An operator then merges the devices, marks them distinct, or dismisses
  the task; each outcome is recorded on the task.

  A decision about devices an operator has already asserted distinct (every pair) opens
  nothing: the operator's decision stands, and the identity decision row still records that
  the merge was refused.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  # Every decision kind that leaves two devices unreconciled. All of them today; listed so a
  # future kind is a deliberate choice.
  @taskable_kinds [
    :policy_block,
    :guard_block,
    :source_block,
    :alias_invalidated,
    :ip_conflict,
    :source_override,
    :component_block
  ]

  @merge_reason "manual_dedup_task"

  @doc """
  Opens or updates the task for each decision naming two or more devices. `decisions` are
  `IdentityDecision` create inputs (`decision_kind`, `reason`, `device_uids`, `evidence`).
  Best-effort, like the decision log: a failure is logged and counted, never raised.
  """
  @spec open_for_decisions([map()]) :: :ok
  def open_for_decisions(decisions) when is_list(decisions) do
    inputs =
      decisions
      |> Enum.filter(&taskable?/1)
      |> Enum.map(&task_input/1)
      |> Enum.uniq_by(&DeduplicationTask.candidate_key(&1.device_uids))
      |> Enum.reject(&all_pairs_asserted_distinct?(&1.device_uids))

    case inputs do
      [] -> :ok
      inputs -> write(inputs)
    end
  rescue
    e -> record_failed(decisions, e)
  end

  @doc "Whether an operator has asserted that `a` and `b` are different devices."
  @spec asserted_distinct?(String.t(), String.t()) :: boolean()
  def asserted_distinct?(a, b) when is_binary(a) and is_binary(b) and a != b do
    [a, b] |> asserted_pairs() |> MapSet.member?(Enum.min_max([a, b]))
  end

  def asserted_distinct?(_a, _b), do: false

  @doc """
  Resolves an open task by merging every other device into `survivor`, one of the task's
  devices, through the administrative merge path (reason `#{@merge_reason}`), then marks the
  task merged. The actor must be allowed to resolve tasks; the merges themselves run as the
  system, as every administrative merge does, and record the requesting actor in their
  details. If any merge fails the task stays open and the error is returned.
  """
  @spec merge(DeduplicationTask.t(), String.t(), term(), keyword()) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def merge(%DeduplicationTask{} = task, survivor, actor, opts \\ []) do
    note = Keyword.get(opts, :note)

    with :ok <- ensure_open(task),
         :ok <- ensure_member(task, survivor),
         :ok <- ensure_can(task, :mark_merged, actor),
         :ok <- merge_all(task, survivor, actor) do
      update(task, :mark_merged, %{merged_into: survivor, resolution_note: note}, actor)
    end
  end

  @doc """
  Resolves an open task as "these are different devices": records a
  `DistinctDeviceAssertion` for every pair of its devices, then marks the task distinct, in one
  transaction. From then on no automatic merge path merges any of those pairs.
  """
  @spec mark_distinct(DeduplicationTask.t(), term(), keyword()) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def mark_distinct(%DeduplicationTask{} = task, actor, opts \\ []) do
    note = Keyword.get(opts, :note)

    with :ok <- ensure_open(task), :ok <- ensure_can(task, :mark_distinct, actor) do
      Repo.transaction(fn ->
        with :ok <- assert_pairs(task, actor, note),
             {:ok, task} <- update(task, :mark_distinct, %{resolution_note: note}, actor) do
          task
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Closes an open task without a decision."
  @spec dismiss(DeduplicationTask.t(), term(), keyword()) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def dismiss(%DeduplicationTask{} = task, actor, opts \\ []) do
    update(task, :dismiss, %{resolution_note: Keyword.get(opts, :note)}, actor)
  end

  # ---------------------------------------------------------------------------------------

  defp taskable?(%{decision_kind: kind, device_uids: uids}) when is_list(uids),
    do: kind in @taskable_kinds and length(DeduplicationTask.normalize_uids(uids)) >= 2

  defp taskable?(_decision), do: false

  defp task_input(decision) do
    kind = to_string(decision.decision_kind)

    %{
      device_uids: DeduplicationTask.normalize_uids(decision.device_uids),
      category: kind,
      last_decision_kind: kind,
      last_reason: decision.reason,
      evidence: Map.get(decision, :evidence) || %{}
    }
  end

  defp all_pairs_asserted_distinct?(uids) do
    pairs = for a <- uids, b <- uids, a < b, do: {a, b}
    asserted = asserted_pairs(uids)
    pairs != [] and Enum.all?(pairs, &MapSet.member?(asserted, &1))
  end

  # The asserted pairs among `uids`, as sorted {device_a, device_b} tuples.
  defp asserted_pairs(uids) do
    DistinctDeviceAssertion
    |> Ash.Query.filter(device_a in ^uids and device_b in ^uids)
    |> Ash.read!(actor: SystemActor.system(:identity_deduplication))
    |> MapSet.new(&{&1.device_a, &1.device_b})
  end

  defp write(inputs) do
    result =
      Ash.bulk_create(inputs, DeduplicationTask, :open_or_update,
        actor: SystemActor.system(:identity_deduplication),
        return_errors?: true,
        stop_on_error?: false,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> record_failed(inputs, errors)
    end
  end

  defp record_failed(inputs, error) do
    Logger.warning(
      "Failed to open #{length(inputs)} de-duplication task(s): #{inspect(error, limit: 20)}"
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :deduplication_task, :open_failed],
      %{count: length(inputs)},
      %{}
    )

    :ok
  end

  defp ensure_open(%DeduplicationTask{status: :open}), do: :ok
  defp ensure_open(%DeduplicationTask{status: status}), do: {:error, {:task_not_open, status}}

  defp ensure_member(%DeduplicationTask{device_uids: uids}, survivor) do
    if survivor in uids, do: :ok, else: {:error, {:survivor_not_in_task, survivor}}
  end

  defp ensure_can(task, action, actor) do
    if Ash.can?({task, action}, actor), do: :ok, else: {:error, :forbidden}
  end

  defp merge_all(task, survivor, actor) do
    task.device_uids
    |> Enum.reject(&(&1 == survivor))
    |> Enum.reduce_while(:ok, fn uid, :ok ->
      case MergeEngine.merge_devices(uid, survivor,
             actor: SystemActor.system(:identity_deduplication),
             reason: @merge_reason,
             details: %{
               "task_id" => task.id,
               "requested_by" => requested_by(actor),
               "source" => "deduplication_task"
             }
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:merge_failed, uid, reason}}}
      end
    end)
  end

  defp requested_by(actor), do: ServiceRadar.Inventory.Changes.SetResolvedBy.actor_name(actor)

  defp assert_pairs(task, actor, note) do
    pairs =
      for a <- task.device_uids, b <- task.device_uids, a < b do
        %{device_a: a, device_b: b, task_id: task.id, note: note}
      end

    result =
      Ash.bulk_create(pairs, DistinctDeviceAssertion, :assert,
        actor: actor,
        return_errors?: true,
        stop_on_error?: true,
        return_records?: false
      )

    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, {:assertion_failed, errors}}
    end
  end

  defp update(task, action, params, actor) do
    task
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update()
  end
end
