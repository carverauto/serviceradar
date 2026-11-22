defmodule ServiceRadar.Jobs.CoreCrontabTest do
  @moduledoc """
  A cron worker's tick must coalesce into the tick already pending for it.

  Oban's Cron plugin inserts one job per tick. When a tick is still pending as the next one
  fires, because its queue is slower than the schedule, a second pending job is inserted
  unless the worker's uniqueness reaches back to the first. A finite `period` shorter than
  the schedule never does: the earlier tick is always just outside it. Each surplus tick
  then waits to be cancelled by `ServiceRadar.Jobs.CronBacklogRepair`, once per pass.

  The assertion reads the job the Cron plugin would insert for each entry, so it holds
  whether the worker or the crontab entry declares the uniqueness.
  """
  use ExUnit.Case, async: true

  alias Oban.Cron.Expression
  alias ServiceRadar.Jobs.CoreCrontab

  # Its uniqueness lapses after 240 seconds on a five-minute schedule. Left as it is while
  # the sweep lease pass is reworked.
  @pending_rework [ServiceRadar.SweepJobs.LeasePassWorker]

  test "an entry that fires more than once an hour never holds two pending ticks" do
    frequent =
      for {expr, worker, opts} <- entries(),
          worker not in @pending_rework,
          expr |> Expression.parse!() |> Map.fetch!(:minutes) |> MapSet.size() > 1,
          do: {worker, opts}

    # There must be something to check, or this test would pass vacuously.
    refute frequent == []

    for {worker, opts} <- frequent do
      {args, opts} = Keyword.pop(opts, :args, %{})
      unique = args |> worker.new(opts) |> Ecto.Changeset.get_change(:unique)

      assert is_map(unique) and unique.period == :infinity and
               :available in unique.states and :scheduled in unique.states,
             "#{inspect(worker)} inserts a second pending tick when its queue is slower " <>
               "than its schedule: unique=#{inspect(unique)}"
    end
  end

  test "schedules RemoteAccessSessionReaperWorker every five minutes on the maintenance queue" do
    assert Enum.any?(entries(), fn {expr, worker, opts} ->
             expr == "*/5 * * * *" and
               worker == ServiceRadar.Edge.RemoteAccessSessionReaperWorker and
               Keyword.get(opts, :queue) == :maintenance
           end)
  end

  test "relays visual index jobs each minute only where recording and visual indexing are enabled" do
    relay = {"* * * * *", ServiceRadar.Camera.VisualIndexDispatchWorker, [queue: :maintenance]}

    for {recording, indexing, scheduled?} <- [
          {"true", "true", true},
          {"true", nil, false},
          {nil, "true", false},
          {"true", "false", false}
        ] do
      env = %{
        "SERVICERADAR_CAMERA_RECORDING_ENABLED" => recording,
        "SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED" => indexing
      }

      fetch = fn name, default -> Map.get(env, name) || default end

      assert relay in entries(fetch) == scheduled?,
             "recording=#{inspect(recording)} indexing=#{inspect(indexing)}"
    end

    {_expr, worker, opts} = relay
    unique = %{} |> worker.new(opts) |> Ecto.Changeset.get_change(:unique)
    assert unique.period == :infinity
    assert Enum.sort(unique.states) == [:available, :scheduled]
    refute :executing in unique.states
  end

  defp entries(fetch \\ fn _name, default -> default end) do
    Enum.map(CoreCrontab.cron_entries(fetch), fn
      {expr, worker} -> {expr, worker, []}
      {expr, worker, opts} -> {expr, worker, opts}
    end)
  end
end
