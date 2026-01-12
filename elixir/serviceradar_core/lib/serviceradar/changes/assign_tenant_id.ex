defmodule ServiceRadar.Changes.AssignTenantId do
  @moduledoc """
  Populates tenant_id from the multitenancy context when missing.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Ash.Resource.Info, as: ResourceInfo

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create &&
         ResourceInfo.attribute(changeset.resource, :tenant_id) do
      tenant_id = resolve_tenant_id(changeset)

      if tenant_id && is_nil(Changeset.get_attribute(changeset, :tenant_id)) do
        Changeset.force_change_attribute(changeset, :tenant_id, tenant_id)
      else
        changeset
      end
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if changeset.action_type == :create &&
         ResourceInfo.attribute(changeset.resource, :tenant_id) do
      tenant_id = resolve_tenant_id(changeset)

      if tenant_id && is_nil(Changeset.get_attribute(changeset, :tenant_id)) do
        {:atomic, %{tenant_id: tenant_id}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp resolve_tenant_id(changeset) do
    actor_tenant_id(changeset) || changeset_tenant_id(changeset)
  end

  defp actor_tenant_id(changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      %{tenant_id: tenant_id} when is_binary(tenant_id) -> tenant_id
      _ -> nil
    end
  end

  defp changeset_tenant_id(%{tenant: tenant_id}) when is_binary(tenant_id) do
    if uuid_string?(tenant_id), do: tenant_id, else: nil
  end

  defp changeset_tenant_id(_changeset), do: nil

  defp uuid_string?(value) do
    Regex.match?(
      ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      value
    )
  end
end
