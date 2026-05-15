defmodule ServiceRadar.Identity.DeviceAuthorizationTest do
  @moduledoc """
  Unit tests for the DeviceAuthorization Ash resource. These verify the
  resource shape (actions, attributes, policies) and the changeset-level
  behavior of state-transition actions without standing up the database.
  Database-backed tests live alongside the controller tests in `web-ng`.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.DeviceAuthorization

  describe "resource shape" do
    test "exposes the RFC 8628 action surface" do
      actions = Info.actions(DeviceAuthorization)
      action_names = Enum.map(actions, & &1.name)

      for required <- [
            :create,
            :read,
            :by_user_code,
            :by_device_code_hash,
            :by_user,
            :pending_active,
            :pending_expired,
            :approve,
            :deny,
            :record_poll,
            :slow_down,
            :expire,
            :destroy
          ] do
        assert required in action_names,
               "DeviceAuthorization must expose the #{inspect(required)} action"
      end
    end

    test "status attribute is constrained to the documented set" do
      attribute = Info.attribute(DeviceAuthorization, :status)
      assert attribute.constraints[:one_of] == [:pending, :approved, :denied, :expired]
      assert attribute.default == :pending
    end

    test "device_code_hash is sensitive and not public" do
      attribute = Info.attribute(DeviceAuthorization, :device_code_hash)
      assert attribute.sensitive? == true
      assert attribute.public? == false
    end

    test "unique identities cover both lookups the controller depends on" do
      identities = DeviceAuthorization |> Info.identities() |> Enum.map(& &1.name)
      assert :unique_user_code in identities
      assert :unique_device_code_hash in identities
    end
  end

  describe ":create" do
    test "stamps :pending status and accepts the documented attribute set" do
      now = DateTime.utc_now()

      changeset =
        Ash.Changeset.for_create(DeviceAuthorization, :create, %{
          attrs: %{
            device_code_hash: String.duplicate("a", 64),
            user_code: "WDJB-MJHT",
            client_id: "serviceradar-cli",
            scope: "dashboard.publish",
            expires_at: DateTime.add(now, 900, :second),
            interval_seconds: 5
          }
        })

      assert changeset.attributes.status == :pending
      assert changeset.attributes.client_id == "serviceradar-cli"
      assert changeset.attributes.user_code == "WDJB-MJHT"
      assert changeset.attributes.device_code_hash == String.duplicate("a", 64)
      assert changeset.attributes.interval_seconds == 5
    end
  end

  describe ":approve" do
    test "flips status to :approved and stamps user_id + approved_at" do
      user_id = Ecto.UUID.generate()

      record = %DeviceAuthorization{
        id: Ecto.UUID.generate(),
        device_code_hash: String.duplicate("a", 64),
        user_code: "WDJB-MJHT",
        client_id: "serviceradar-cli",
        scope: "dashboard.publish",
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
        interval_seconds: 5
      }

      changeset = Ash.Changeset.for_update(record, :approve, %{user_id: user_id})

      assert changeset.attributes.status == :approved
      assert changeset.attributes.user_id == user_id
      assert %DateTime{} = changeset.attributes.approved_at
    end
  end

  describe ":deny" do
    test "flips status to :denied and leaves user_id alone" do
      record = %DeviceAuthorization{
        id: Ecto.UUID.generate(),
        device_code_hash: String.duplicate("b", 64),
        user_code: "ABCD-EFGH",
        client_id: "serviceradar-cli",
        scope: "dashboard.publish",
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
        interval_seconds: 5
      }

      changeset = Ash.Changeset.for_update(record, :deny, %{})

      assert changeset.attributes[:status] == :denied
      refute Map.has_key?(changeset.attributes, :user_id)
    end
  end
end
