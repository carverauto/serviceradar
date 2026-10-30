defmodule ServiceRadar.Edge.Changes.GuardComponentCertificateIssuance do
  @moduledoc false
  use Ash.Resource.Change

  alias ServiceRadar.Edge.ManagedComponent

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :generation,
      Ash.Changeset.get_argument(changeset, :expected_generation)
    )
    |> Ash.Changeset.before_action(fn changeset ->
      id = Ash.Changeset.get_attribute(changeset, :component_id)
      generation = Ash.Changeset.get_argument(changeset, :expected_generation)
      host = Ash.Changeset.get_argument(changeset, :host_agent_id)
      role = Ash.Changeset.get_attribute(changeset, :role)

      result =
        ManagedComponent
        |> Ash.Query.filter(component_id == ^id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one(actor: context.actor)

      case result do
        {:ok, %{blocked: false, generation: ^generation, host_agent_id: ^host} = component} ->
          if valid_role?(component.component_type, role) do
            Ash.Changeset.force_change_attribute(changeset, :generation, generation)
          else
            Ash.Changeset.add_error(changeset,
              field: :role,
              message: "role does not belong to this component"
            )
          end

        _ ->
          Ash.Changeset.add_error(changeset,
            field: :component_id,
            message: "component issuance binding is unavailable, blocked, or stale"
          )
      end
    end)
  end

  defp valid_role?("nats-leaf", role), do: role in ["upstream_client", "local_server"]
  defp valid_role?(_type, role), do: role == "client"
end
