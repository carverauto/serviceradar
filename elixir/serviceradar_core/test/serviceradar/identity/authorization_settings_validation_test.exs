defmodule ServiceRadar.Identity.AuthorizationSettingsValidationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.TestSupport

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
        %{"source" => "email", "value" => "user@example.com", "role" => "viewer", "claim" => "email"}
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

    assert {:error, error} = AuthorizationSettings.create_settings(email_domain_attrs, actor: actor)
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
