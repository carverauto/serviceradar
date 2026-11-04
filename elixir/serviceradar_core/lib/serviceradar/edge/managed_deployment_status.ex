defmodule ServiceRadar.Edge.ManagedDeploymentStatus do
  @moduledoc """
  Installation state for an edge site or collector, independent of legacy bundle
  provisioning. An acknowledged activation in the current enrollment generation
  stays installed while a later renewal is in progress or has failed. An
  acknowledged installation is not a runtime heartbeat.
  """
  use Ash.Resource.Calculation

  @impl true
  def expression(_opts, _context) do
    expr(
      cond do
        type(status, :string) == "revoked" ->
          type(status, :string)

        is_nil(managed_component.component_id) ->
          type(status, :string)

        managed_component.blocked ->
          "revoked"

        exists(managed_component.installed_operations, true) ->
          "installed"

        is_nil(managed_component.current_operation.id) ->
          "pending"

        managed_component.current_operation.generation != managed_component.generation ->
          "pending"

        managed_component.current_operation.status == :failed ->
          "failed"

        true ->
          "installing"
      end
    )
  end
end
