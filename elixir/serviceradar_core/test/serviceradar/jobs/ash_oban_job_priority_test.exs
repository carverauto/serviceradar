defmodule ServiceRadar.Jobs.AshObanJobPriorityTest do
  @moduledoc """
  AshOban schedulers and workers share their queues with priority-0 work. Oban
  fetches by priority before age, so a job enqueued at AshOban's default
  priority (3 for a scheduler, 2 for a worker) is not fetched while any
  priority-0 job in its queue is available, and its schedule stops without a
  failure. Every AshOban job is therefore enqueued at priority 0.
  """

  use ExUnit.Case, async: true

  test "every AshOban scheduler and worker enqueues its job at priority 0" do
    modules =
      :serviceradar_core
      |> Application.get_env(:ash_domains, [])
      |> List.wrap()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.flat_map(&AshOban.Info.oban_triggers_and_scheduled_actions/1)
      |> Enum.flat_map(fn declared -> [Map.get(declared, :scheduler), declared.worker] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # There must be something to check, or this test would pass vacuously.
    refute modules == []

    lowered =
      for module <- modules,
          priority = Ecto.Changeset.get_field(module.new(%{}), :priority),
          priority != 0,
          do: {module, priority}

    assert lowered == [],
           "these AshOban jobs are enqueued below priority 0 and starve behind " <>
             "priority-0 work in their queue: #{inspect(lowered)}"
  end
end
