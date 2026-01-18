defmodule ServiceRadar.SweepJobs.ObanSupport do
  @moduledoc """
  Helpers for safely interacting with Oban from sweep job workflows.

  This prevents user-facing actions from crashing when Oban isn't running
  in the current process (e.g., web-ng).
  """

  @spec available?() :: boolean()
  def available? do
    case Oban.Registry.whereis(Oban) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @spec safe_insert(Oban.Job.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def safe_insert(job) do
    if available?() do
      try do
        Oban.insert(job)
      rescue
        e in RuntimeError ->
          {:error, {:oban_unavailable, Exception.message(e)}}

        e ->
          {:error, {:oban_insert_failed, e}}
      end
    else
      {:error, :oban_unavailable}
    end
  end
end
