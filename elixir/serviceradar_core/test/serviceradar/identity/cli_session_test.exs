defmodule ServiceRadar.Identity.CliSessionTest do
  @moduledoc """
  Unit tests for the CliSession Ash resource. Verifies the resource shape +
  the changeset-level behavior of `:create`, `:revoke`, and `:record_use`
  without standing up the database.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.CliSession

  describe "resource shape" do
    test "exposes the action surface the controller + Settings UI need" do
      action_names = CliSession |> Info.actions() |> Enum.map(& &1.name)

      for required <- [
            :create,
            :read,
            :by_jti,
            :active_by_user,
            :active,
            :expired_active,
            :revoke,
            :record_use,
            :mark_expired,
            :destroy
          ] do
        assert required in action_names,
               "CliSession must expose the #{inspect(required)} action"
      end
    end

    test "status attribute is constrained to the documented set" do
      attribute = Info.attribute(CliSession, :status)
      assert attribute.constraints[:one_of] == [:active, :revoked, :expired]
      assert attribute.default == :active
    end

    test "jti is the primary key (used by the ApiAuth plug post-verify lookup)" do
      jti = Info.attribute(CliSession, :jti)
      assert jti.primary_key? == true
      assert jti.allow_nil? == false
    end
  end

  describe ":create" do
    test "stamps :active status and accepts the documented attribute set" do
      user_id = Ecto.UUID.generate()
      device_authorization_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      changeset =
        Ash.Changeset.for_create(CliSession, :create, %{
          attrs: %{
            jti: "abc123",
            device_authorization_id: device_authorization_id,
            user_id: user_id,
            client_id: "serviceradar-cli",
            scope: "dashboard.publish",
            issued_at: now,
            expires_at: DateTime.add(now, 30 * 24 * 3600, :second)
          }
        })

      assert changeset.attributes.status == :active
      assert changeset.attributes.jti == "abc123"
      assert changeset.attributes.user_id == user_id
      assert changeset.attributes.device_authorization_id == device_authorization_id
    end
  end

  describe ":revoke" do
    test "flips status to :revoked and stamps the revoking actor + timestamp" do
      record = %CliSession{
        jti: "xyz789",
        user_id: Ecto.UUID.generate(),
        client_id: "serviceradar-cli",
        scope: "dashboard.publish",
        status: :active,
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      }

      changeset = Ash.Changeset.for_update(record, :revoke, %{revoked_by: "user-uuid"})

      assert changeset.attributes.status == :revoked
      assert changeset.attributes.revoked_by == "user-uuid"
      assert %DateTime{} = changeset.attributes.revoked_at
    end
  end

  describe ":mark_expired" do
    test "flips status to :expired (cleanup transition)" do
      record = %CliSession{
        jti: "expired-1",
        user_id: Ecto.UUID.generate(),
        client_id: "serviceradar-cli",
        scope: "dashboard.publish",
        status: :active,
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }

      changeset = Ash.Changeset.for_update(record, :mark_expired, %{})

      assert changeset.attributes.status == :expired
    end
  end
end
