defmodule ServiceRadar.CompositeChecks.Refresh do
  @moduledoc """
  Debounced per-device re-evaluation, triggered when one of a device's input
  signals changes.

  ## What this refreshes, and what it deliberately does not

  Only the enabled checks that already hold a result row for the device are
  re-evaluated. A device newly entering a check's scope is picked up by the
  periodic pass instead.

  The alternative — re-running every enabled check's SRQL scope with a UID
  filter on every sweep result — costs one SRQL translation and query per check
  per device per sweep cycle. That is a far worse trade than a bounded delay on
  scope entry, so this asymmetry is intentional rather than an oversight.

  `enqueue/1` and `enqueue_many/1` never raise and never block the caller: they
  run inside sweep result ingestion, which must not fail because a composite
  check refresh could not be scheduled.
  """

  alias ServiceRadar.CompositeChecks.RefreshWorker
  alias ServiceRadar.Inventory.Identity.Fence
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @spec enqueue(String.t()) :: :ok
  def enqueue(device_uid) when is_binary(device_uid) and device_uid != "" do
    enqueue_many([device_uid])
  end

  def enqueue(_device_uid), do: :ok

  @spec enqueue_many([String.t()]) :: :ok
  def enqueue_many(device_uids) when is_list(device_uids) do
    if ObanSupport.available?() do
      uids =
        device_uids
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.uniq()

      # One read for the whole batch. This runs inside sweep result ingestion and
      # can carry thousands of uids, so a per-device pin would add a query each.
      revisions = Fence.observe_pins(uids)

      Enum.each(uids, &insert(&1, revisions))
    end

    :ok
  rescue
    exception ->
      Logger.debug("composite check refresh not enqueued",
        reason: Exception.message(exception)
      )

      :ok
  end

  def enqueue_many(_device_uids), do: :ok

  # The pinned revision rides along in the job args so the worker can tell whether
  # identity moved during the debounce window. Observe-only: a uid whose revision
  # could not be read is enqueued exactly as before, without the key.
  defp insert(device_uid, revisions) do
    %{device_uid: device_uid}
    |> put_pin(Map.get(revisions, device_uid))
    |> RefreshWorker.new()
    |> ObanSupport.safe_insert()
  end

  defp put_pin(args, revision) when is_integer(revision),
    do: Map.put(args, :identity_revision, revision)

  defp put_pin(args, _revision), do: args
end
