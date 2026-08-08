defmodule ServiceRadar.Edge.RemoteAccessSessionPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.RemoteAccessSession

  @moduletag :requires_app

  @ssh_permission "devices.remote_access.ssh.open"
  @rdp_permission "devices.remote_access.rdp.open"
  @moduletag :db_free

  test "an RDP-only actor can create RDP but cannot create SSH sessions" do
    actor = actor_with(@rdp_permission)

    assert allowed?(:rdp, actor)
    refute allowed?(:ssh, actor)
  end

  test "an SSH-only actor can create SSH but cannot create RDP sessions" do
    actor = actor_with(@ssh_permission)

    assert allowed?(:ssh, actor)
    refute allowed?(:rdp, actor)
  end

  test "non-SSH and non-RDP protocols fail closed for a user actor" do
    actor = actor_with([@ssh_permission, @rdp_permission])

    refute allowed?(:tcp, actor)
  end

  test "the system actor bypass remains available for internal protocols" do
    assert allowed?(:tcp, SystemActor.system(:remote_access_policy_test))
  end

  defp allowed?(protocol, actor) do
    adapter = if protocol == :tcp, do: :tcp, else: protocol
    port = if protocol == :rdp, do: 3389, else: 22

    changeset =
      Ash.Changeset.for_create(RemoteAccessSession, :create, %{
        attach_ticket_hash: unique("ticket"),
        attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        target_kind: :inventory_device,
        target_host: "target.example.test",
        target_port: port,
        protocol: protocol,
        adapter: adapter,
        agent_id: "agent-policy-test",
        gateway_id: "gateway-policy-test",
        credential_custody_mode: if(protocol == :ssh, do: :ssh_certificate, else: :none),
        rbac_decision: :allowed,
        metadata: %{}
      })

    Ash.can?(changeset, actor)
  end

  defp actor_with(permission) when is_binary(permission), do: actor_with([permission])

  defp actor_with(permissions) do
    %{
      id: Ecto.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new(permissions)
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
