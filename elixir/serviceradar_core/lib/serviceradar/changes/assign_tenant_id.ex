defmodule ServiceRadar.Changes.AssignTenantId do
  @moduledoc """
  Populates tenant_id from the multitenancy context when missing.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create &&
         Ash.Resource.Info.attribute(changeset.resource, :tenant_id) do
      tenant_id = resolve_tenant_id(changeset)

      if tenant_id && is_nil(Ash.Changeset.get_attribute(changeset, :tenant_id)) do
        Ash.Changeset.force_change_attribute(changeset, :tenant_id, tenant_id)
      else
        changeset
      end
    else
      changeset
    end
  end

  defp resolve_tenant_id(changeset) do
    with %{tenant_id: tenant_id} when is_binary(tenant_id) <- changeset.actor do
      tenant_id
    else
      _ ->
        case changeset.tenant do
          tenant_id when is_binary(tenant_id) ->
            if uuid_string?(tenant_id), do: tenant_id, else: nil

          _ ->
            nil
        end
    end
  end

  defp uuid_string?(value) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      value
    )
  end
end
