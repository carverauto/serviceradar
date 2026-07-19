defmodule ServiceRadar.PrefixTags.ObanSchedule do
  @moduledoc """
  Shared Oban scheduling helpers for prefix-tag maintenance workers
  (NetBox import, TI/DNS materializers, …).
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  @successor_unique [period: :infinity, states: [:available, :scheduled, :retryable]]

  @doc "Insert the worker job if none is already incomplete."
  @spec ensure_scheduled(module()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(worker_mod) when is_atom(worker_mod) do
    if ObanSupport.available?() do
      if job_exists?(worker_mod) do
        {:ok, :already_scheduled}
      else
        %{} |> worker_mod.new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @doc "Schedule a unique successor job after `seconds`."
  @spec schedule_next(module(), pos_integer()) :: :ok
  def schedule_next(worker_mod, seconds) when is_atom(worker_mod) and is_integer(seconds) do
    _ =
      %{}
      |> worker_mod.new(schedule_in: max(seconds, 60), unique: @successor_unique)
      |> ObanSupport.safe_insert()

    :ok
  end

  @doc "True when this node should run coordinator-style maintenance jobs."
  @spec scheduler_node?() :: boolean()
  def scheduler_node? do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

    cluster_coordinator =
      Application.get_env(:serviceradar_core, :cluster_coordinator, cluster_enabled)

    if cluster_enabled, do: cluster_coordinator == true, else: true
  end

  defp job_exists?(worker_mod) do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(worker_mod),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
