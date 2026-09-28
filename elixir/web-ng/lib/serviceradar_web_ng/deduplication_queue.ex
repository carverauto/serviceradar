defmodule ServiceRadarWebNG.DeduplicationQueue do
  @moduledoc """
  Read model and operator actions for the identity de-duplication review queue.

  A de-duplication task is a set of devices identity reconciliation refused to merge on its
  own (`ServiceRadar.Inventory.DeduplicationTask`). Reads go through the task, device and
  identity-decision resources as the signed-in user, so their policies decide what a viewer
  sees. Resolutions call `ServiceRadar.Inventory.Identity.Deduplication`, which checks that the
  user may resolve the task (operators and admins) before it changes anything.
  """

  alias ServiceRadar.Inventory.DeduplicationTask
  alias ServiceRadar.Inventory.DeduplicationTaskNotifier
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.IdentityDecision

  require Ash.Query

  # The signed-in user's `ServiceRadarWebNG.Accounts.Scope`; matched structurally because this
  # context sits outside the Accounts boundary.
  @type scope :: %{required(:user) => term(), optional(atom()) => term()}

  @statuses [:open, :dismissed, :merged, :distinct]
  @page_limit 200
  @decision_limit 50

  @doc "Task statuses, in the order the queue offers them as filters."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The most tasks one page of the queue lists."
  @spec page_limit() :: pos_integer()
  def page_limit, do: @page_limit

  @doc "Subscribe the calling process to task resolutions made anywhere."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: DeduplicationTaskNotifier.subscribe()

  @doc "Tasks with `status` (or every task for `:all`), most recently decided first."
  @spec list_tasks(scope(), atom()) :: {:ok, [DeduplicationTask.t()]} | {:error, term()}
  def list_tasks(scope, status) when status in @statuses or status == :all do
    DeduplicationTask
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> filter_status(status)
    |> Ash.Query.sort(last_decided_at: :desc, id: :desc)
    |> Ash.Query.limit(@page_limit)
    |> Ash.read()
  end

  @doc "One task, or `{:error, :not_found}`."
  @spec get_task(scope(), String.t()) :: {:ok, DeduplicationTask.t()} | {:error, term()}
  def get_task(scope, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case DeduplicationTask.get_by_id(uuid, scope: scope, not_found_error?: false) do
          {:ok, nil} -> {:error, :not_found}
          other -> other
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  The task's devices keyed by uid, tombstoned ones included: a device merged away since the
  task opened still has to be shown, not silently dropped.
  """
  @spec devices(scope(), [String.t()]) :: {:ok, %{String.t() => Device.t()}} | {:error, term()}
  def devices(scope, uids) when is_list(uids) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true}, scope: scope)
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.read(page: [limit: max(length(uids), 1)])
    |> case do
      {:ok, page} -> {:ok, Map.new(results(page), &{&1.uid, &1})}
      error -> error
    end
  end

  @doc "The identity decisions about exactly this task's device set, most recent first."
  @spec decisions(scope(), DeduplicationTask.t()) ::
          {:ok, [IdentityDecision.t()]} | {:error, term()}
  def decisions(scope, %DeduplicationTask{device_uids: uids}) do
    IdentityDecision
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(device_uids == ^uids)
    |> Ash.Query.sort(last_decided_at: :desc)
    |> Ash.Query.limit(@decision_limit)
    |> Ash.read()
  end

  @doc "Whether the user may resolve, dismiss and reopen tasks."
  @spec can_resolve?(scope()) :: boolean()
  def can_resolve?(%{user: nil}), do: false
  def can_resolve?(%{user: user}), do: Ash.can?({DeduplicationTask, :dismiss}, user)

  @doc "Merge every other device of an open task into `survivor`."
  @spec merge(scope(), DeduplicationTask.t(), String.t(), String.t() | nil) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def merge(%{user: user}, %DeduplicationTask{} = task, survivor, note) do
    Deduplication.merge(task, survivor, user, note: blank_to_nil(note))
  end

  @doc "Record that an open task's devices are different devices."
  @spec mark_distinct(scope(), DeduplicationTask.t(), String.t() | nil) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def mark_distinct(%{user: user}, %DeduplicationTask{} = task, note) do
    Deduplication.mark_distinct(task, user, note: blank_to_nil(note))
  end

  @doc "Close an open task without a decision."
  @spec dismiss(scope(), DeduplicationTask.t(), String.t() | nil) ::
          {:ok, DeduplicationTask.t()} | {:error, term()}
  def dismiss(%{user: user}, %DeduplicationTask{} = task, note) do
    Deduplication.dismiss(task, user, note: blank_to_nil(note))
  end

  @doc "Reopen a dismissed task."
  @spec reopen(scope(), DeduplicationTask.t()) :: {:ok, DeduplicationTask.t()} | {:error, term()}
  def reopen(%{user: user}, %DeduplicationTask{} = task), do: Deduplication.reopen(task, user)

  @doc "A sentence for an operator explaining why an action did not happen."
  @spec error_message(term()) :: String.t()
  def error_message(:forbidden), do: "You are not allowed to resolve de-duplication tasks."
  def error_message(:not_found), do: "That de-duplication task no longer exists."

  def error_message({:task_not_open, status}),
    do: "The task is already #{status}; reload the queue to see its current state."

  def error_message({:survivor_not_in_task, _uid}), do: "Choose one of the task's devices to keep."

  def error_message({:merge_failed, uid, reason}), do: "Merging #{uid} failed (#{inspect(reason)}); the task stays open."

  def error_message(%Ash.Error.Forbidden{}), do: error_message(:forbidden)
  def error_message(%Ash.Error.Invalid{}), do: "The task is not in a state that allows this action."
  def error_message(_reason), do: "The action failed; the task was not changed."

  defp filter_status(query, :all), do: query
  defp filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp results(%{results: results}), do: results
  defp results(results) when is_list(results), do: results

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 500)
    end
  end
end
