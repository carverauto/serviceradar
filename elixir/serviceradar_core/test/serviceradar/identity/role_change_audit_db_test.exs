defmodule ServiceRadar.Identity.RoleChangeAuditDbTest do
  @moduledoc """
  Database integration tests verifying admin role changes append immutable audit rows to
  platform.user_auth_events (SEC-254a85d2).
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserAuthEvent
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    system = SystemActor.system(:role_change_audit_test)
    admin = user!(system, :admin)
    target = user!(system, :viewer)

    {:ok, system: system, admin: admin, target: target}
  end

  test "admin updating a user's role writes exactly one audit event with actor, old and new role",
       %{
         admin: admin,
         target: target
       } do
    initial_events = list_events!(target.id)

    {:ok, updated} = User.update_role(target, %{role: :operator}, actor: admin)
    assert updated.role == :operator

    events = list_events!(target.id)
    assert length(events) == length(initial_events) + 1

    [event | _] = events
    assert event.event_type == "role_change"
    assert event.user_id == target.id
    assert event.actor_user_id == admin.id
    assert event.metadata["old_role"] == "viewer"
    assert event.metadata["new_role"] == "operator"
    assert event.metadata["actor"] == admin.email
  end

  test "updating to the same role does not write an audit event", %{
    admin: admin,
    target: target
  } do
    initial_events = list_events!(target.id)

    {:ok, _} = User.update_role(target, %{role: :viewer}, actor: admin)

    events = list_events!(target.id)
    assert length(events) == length(initial_events)
  end

  test "system actor role change records audit event with nil actor_user_id", %{
    system: system,
    target: target
  } do
    initial_events = list_events!(target.id)

    {:ok, updated} = User.update_role(target, %{role: :admin}, actor: system)
    assert updated.role == :admin

    events = list_events!(target.id)
    assert length(events) == length(initial_events) + 1

    [event | _] = events
    assert event.event_type == "role_change"
    assert event.user_id == target.id
    assert event.actor_user_id == nil
    assert event.metadata["old_role"] == "viewer"
    assert event.metadata["new_role"] == "admin"
    assert event.metadata["actor"] == system.email
  end

  defp list_events!(user_id) do
    UserAuthEvent.list_for_user!(user_id).results
  end

  defp user!(actor, role) do
    suffix = System.unique_integer([:positive])
    password = "password_#{suffix}_Aa1!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "audit-role-#{role}-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: actor
      )

    {:ok, user} = User.update_role(user, %{role: role}, actor: actor)
    user
  end
end
