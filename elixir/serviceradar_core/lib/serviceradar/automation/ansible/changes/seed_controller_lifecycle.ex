defmodule ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle do
  @moduledoc """
  Ash change that converges AWX/AAP controller jobs and plugin assignments after
  controller writes. `mode: :seed` (create/update) seeds jobs + materializes the
  inventory-sync assignment; `mode: :teardown` (destroy) retracts the removed
  controller's assignment contribution without re-seeding its jobs.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Automation.Ansible.Lifecycle
  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, opts, _context) do
    case Keyword.get(opts, :mode, :seed) do
      :teardown ->
        AfterAction.after_action(changeset, &Lifecycle.teardown_controller/1)

      _ ->
        AfterAction.after_action(changeset, fn controller ->
          # A create/update that leaves the controller disabled must retract, not
          # seed: pausing a controller stops its jobs and pulls its inventory-sync
          # assignment while retaining the row.
          if enabled?(controller) do
            Lifecycle.seed_controller(controller)
          else
            Lifecycle.teardown_controller(controller)
          end
        end)
    end
  end

  defp enabled?(controller) do
    case Map.get(controller, :enabled) do
      false -> false
      _ -> true
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
