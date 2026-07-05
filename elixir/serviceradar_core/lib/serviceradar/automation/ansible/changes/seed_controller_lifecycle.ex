defmodule ServiceRadar.Automation.Ansible.Changes.SeedControllerLifecycle do
  @moduledoc """
  Ash change that seeds AWX/AAP controller jobs and plugin assignments after
  controller writes.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Automation.Ansible.Lifecycle
  alias ServiceRadar.Changes.AfterAction

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &Lifecycle.seed_controller/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
