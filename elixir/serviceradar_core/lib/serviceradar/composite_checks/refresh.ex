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
      device_uids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.each(&insert/1)
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

  defp insert(device_uid) do
    %{device_uid: device_uid}
    |> RefreshWorker.new()
    |> ObanSupport.safe_insert()
  end
end
