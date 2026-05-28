defmodule ServiceRadar.Security.AuditHistoryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.AuditHistory
  alias ServiceRadar.Security.AuthLockout

  describe "resources/0" do
    test "returns the configured allow-list when set" do
      previous = Application.get_env(:serviceradar_core, AuditHistory, [])

      try do
        Application.put_env(:serviceradar_core, AuditHistory, resources: [AuthLockout])

        assert AuditHistory.resources() == [AuthLockout]
      after
        Application.put_env(:serviceradar_core, AuditHistory, previous)
      end
    end

    test "falls back to a default list when no config is set" do
      previous = Application.get_env(:serviceradar_core, AuditHistory, [])

      try do
        Application.delete_env(:serviceradar_core, AuditHistory)

        defaults = AuditHistory.resources()
        assert is_list(defaults)
        assert AuthLockout in defaults
        assert ServiceRadar.Credentials.NetworkCredentialSecret in defaults
        assert ServiceRadar.Inventory.VisibilityProfile in defaults
      after
        Application.put_env(:serviceradar_core, AuditHistory, previous)
      end
    end
  end

  describe "actor_id filter" do
    test "matches when inputs.actor is a string identifier" do
      version = build_version(%{"actor" => "alice@example.com"})

      assert AuditHistory.__matches_actor__?(version, "alice@example.com")
      refute AuditHistory.__matches_actor__?(version, "bob@example.com")
    end

    test "matches when inputs.actor.id is the canonical identifier" do
      version = build_version(%{"actor" => %{"id" => "user-42"}})

      assert AuditHistory.__matches_actor__?(version, "user-42")
    end

    test "matches when inputs.actor.email is the identifier" do
      version = build_version(%{"actor" => %{"email" => "carol@example.com"}})

      assert AuditHistory.__matches_actor__?(version, "carol@example.com")
    end

    test "nil / empty actor_id always matches" do
      version = build_version(%{})

      assert AuditHistory.__matches_actor__?(version, nil)
      assert AuditHistory.__matches_actor__?(version, "")
    end
  end

  defp build_version(action_inputs) do
    %{
      resource: AuthLockout,
      version: %{
        version_action_inputs: action_inputs,
        version_inserted_at: DateTime.utc_now()
      }
    }
  end
end
