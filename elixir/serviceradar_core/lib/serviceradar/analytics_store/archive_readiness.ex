defmodule ServiceRadar.AnalyticsStore.ArchiveReadiness do
  @moduledoc """
  Wait for the archive work visible when a historical query begins.

  The snapshot is fixed: incoming telemetry cannot extend the wait indefinitely.
  This runs on the primary before file selection or analytics pool checkout.
  """

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.AnalyticsStore.Config

  @doc "Require all overlapping batches in the initial snapshot to be published."
  @spec await(String.t(), {DateTime.t() | nil, DateTime.t() | nil}, keyword()) ::
          :ok | {:error, term()}
  def await(table, window, opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    if Config.driver_for(cfg, table) == :hybrid do
      timeout = Keyword.get(opts, :archive_wait_timeout, 5_000)
      deadline = System.monotonic_time(:millisecond) + timeout
      snapshot = Keyword.get(opts, :archive_pending_fn, &ArchiveBatch.pending_ids_for_window/3)

      with {:ok, ids} <- snapshot.(table, window, timeout: timeout) do
        wait_for(ids, deadline, opts)
      end
    else
      :ok
    end
  end

  defp wait_for([], _deadline, _opts), do: :ok

  defp wait_for(ids, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :analytics_archive_not_ready}
    else
      published = Keyword.get(opts, :archive_published_fn, &ArchiveBatch.published_ids?/2)

      case published.(ids, timeout: remaining) do
        {:ok, true} ->
          :ok

        {:ok, false} ->
          sleep = Keyword.get(opts, :archive_sleep_fn, &Process.sleep/1)
          sleep.(min(100, remaining))
          wait_for(ids, deadline, opts)

        {:error, _} = error ->
          error
      end
    end
  end
end
