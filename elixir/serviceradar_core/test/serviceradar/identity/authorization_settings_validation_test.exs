defmodule ServiceRadar.Identity.AuthorizationSettingsValidationTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:authorization_settings_validation_test)
    {:ok, actor: actor}
  end

  test "accepts valid role mappings", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "groups", "value" => "admins", "role" => "admin", "claim" => "groups"},
        %{"source" => "email_domain", "value" => "example.com", "role" => "operator"},
        %{"source" => "claim", "value" => "true", "role" => "viewer", "claim" => "is_read_only"}
      ]
    }

    assert {:ok, settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert settings.default_role == :viewer
    assert Enum.count(settings.role_mappings) == 3
  end

  test "accepts a mapping that grants a role profile instead of a role", %{actor: actor} do
    # The point of the change: a group can now grant a permission set, not just
    # one of the four built-in roles.
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{
          "source" => "groups",
          "value" => "SR-Plugin-Authors",
          "role_profile_id" => Ecto.UUID.generate()
        }
      ]
    }

    assert {:ok, settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Enum.count(settings.role_mappings) == 1
  end

  test "accepts a mapping that grants a user group", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "groups", "value" => "SR-Ops", "user_group_id" => Ecto.UUID.generate()}
      ]
    }

    assert {:ok, _settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
  end

  test "rejects a mapping that grants nothing", %{actor: actor} do
    # `role` used to be mandatory, so "grants nothing" was unrepresentable.
    # Now that it is optional, a mapping with no grant would match and do
    # nothing at all.
    attrs = %{
      default_role: :viewer,
      role_mappings: [%{"source" => "groups", "value" => "SR-Nobody"}]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "must grant at least one of"
  end

  test "still rejects an invalid role string now that role is optional", %{actor: actor} do
    # Regression guard: normalize_role/1 returns nil for an unknown role, so a
    # naive "nil is fine now" clause would accept role: "bogus".
    attrs = %{
      default_role: :viewer,
      role_mappings: [%{"source" => "groups", "value" => "SR-Bad", "role" => "bogus"}]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "role must be one of"
  end

  test "rejects a non-UUID role profile id", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "groups", "value" => "SR-Bad", "role_profile_id" => "not-a-uuid"}
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "role_profile_id must be a UUID"
  end

  test "rejects invalid source", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "not-a-source", "value" => "admins", "role" => "admin"}
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "source must be one of"
  end

  test "requires claim for claim source", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "claim", "value" => "true", "role" => "admin"}
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "claim is required for source 'claim'"
  end

  test "rejects claim for email sources", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{
          "source" => "email",
          "value" => "user@example.com",
          "role" => "viewer",
          "claim" => "email"
        }
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "claim is not allowed for source 'email'"
  end

  test "rejects malformed email and email_domain values", %{actor: actor} do
    email_domain_attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "email_domain", "value" => "user@example.com", "role" => "viewer"}
      ]
    }

    assert {:error, error} =
             AuthorizationSettings.create_settings(email_domain_attrs, actor: actor)

    assert Exception.message(error) =~ "domain"

    email_attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "email", "value" => "example.com", "role" => "viewer"}
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(email_attrs, actor: actor)
    assert Exception.message(error) =~ "email address"
  end

  test "rejects unexpected keys", %{actor: actor} do
    attrs = %{
      default_role: :viewer,
      role_mappings: [
        %{"source" => "groups", "value" => "admins", "role" => "admin", "extra" => "nope"}
      ]
    }

    assert {:error, error} = AuthorizationSettings.create_settings(attrs, actor: actor)
    assert Exception.message(error) =~ "unexpected keys"
  end
end
