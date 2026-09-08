defmodule ServiceRadar.Edge.Checks.ActorCanCreateRemoteAccessProtocol do
  @moduledoc """
  Authorizes remote-access session creation for the requested protocol.

  The protocol comes from the create changeset, so a permission for one
  transport cannot be reused to create another transport's session.
  """

  use Ash.Policy.SimpleCheck

  alias Ash.Policy.Authorizer
  alias ServiceRadar.Identity.RBAC

  @ssh_permission "devices.remote_access.ssh.open"
  @rdp_permission "devices.remote_access.rdp.open"

  @impl true
  def describe(_opts),
    do: "actor has the permission required by the requested remote-access protocol"

  @impl true
  def match?(actor, %Authorizer{} = authorizer, opts) when is_list(opts) do
    match?(actor, %{changeset: Map.get(authorizer, :changeset)}, opts)
  end

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) when not is_nil(actor) do
    changeset
    |> Ash.Changeset.get_attribute(:protocol)
    |> required_permission()
    |> actor_has_permission?(actor)
  end

  def match?(_actor, _context, _opts), do: false

  defp required_permission(:ssh), do: @ssh_permission
  defp required_permission("ssh"), do: @ssh_permission
  defp required_permission(:rdp), do: @rdp_permission
  defp required_permission("rdp"), do: @rdp_permission
  defp required_permission(_protocol), do: nil

  defp actor_has_permission?(nil, _actor), do: false

  defp actor_has_permission?(permission, %{permissions: %MapSet{} = permissions}),
    do: MapSet.member?(permissions, permission)

  defp actor_has_permission?(permission, actor), do: RBAC.has_permission?(actor, permission)
end
