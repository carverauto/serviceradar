defmodule ServiceRadar.Credentials.CredentialRotationDbTest do
  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Ash.Error.Forbidden
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialRotation
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Repo

  @moduletag :integration

  @credential_permission "settings.credentials.manage"
  @system_actor SystemActor.system(:credential_rotation_db_test)

  test "default rotation path refreshes authority and descriptor, backfills legacy metadata, and redacts secret material" do
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    provider = "credential-rotation-db-#{suffix}"
    plugin_id = "credential-rotation-db-plugin-#{suffix}"
    password_marker = "rotation-db-secret-marker-#{suffix}"
    due_at = DateTime.add(DateTime.utc_now(), 86_400, :second)

    package = approved_descriptor_fixture!(plugin_id, provider)
    user = credential_manager!(suffix)
    human_actor = human_actor(user)

    secret =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "legacy-rotation-secret-#{suffix}",
          provider: provider,
          credential_kind: :username_password,
          username: "legacy-user",
          secret_payload: "legacy-password",
          source_type: :internal_encrypted,
          next_rotation_due_at: due_at,
          metadata: %{}
        },
        actor: @system_actor
      )
      |> Ash.create!(actor: @system_actor)

    assert {:ok, catalog_profile} =
             IntegrationCatalog.profile_for(provider, actor: @system_actor)

    assert catalog_profile["plugin_id"] == plugin_id
    assert catalog_profile["plugin_package_id"] == package.id
    assert catalog_profile["plugin_version"] == package.version

    assert {:error, %Forbidden{}} =
             secret
             |> Ash.Changeset.for_update(:start_rotation, %{}, actor: human_actor)
             |> Ash.update(actor: human_actor)

    # Cached caller authority is deliberately false. The production boundary
    # must reload this persisted user's current role profile before acting.
    stale_scope = %{
      user: %{id: user.id, role: :viewer},
      permissions: MapSet.new(["forged.stale.permission"])
    }

    {{:ok, rotated}, log} =
      with_log(fn ->
        CredentialRotation.rotate(
          secret,
          %{"username" => "replacement-user", "password" => password_marker},
          stale_scope
        )
      end)

    assert rotated.rotation_state == :active
    assert rotated.username == "replacement-user"
    assert DateTime.compare(rotated.next_rotation_due_at, due_at) == :eq
    assert rotated.metadata["credential_descriptor"] == "package_manifest.v1"
    assert rotated.metadata["auth_method"] == "username_password"
    assert rotated.metadata["plugin_id"] == plugin_id
    assert rotated.metadata["plugin_version"] == package.version
    assert is_nil(rotated.last_rotation_failure_message)
    refute log =~ password_marker

    assert {:ok, %{value: ^password_marker}} =
             SecretBroker.resolve_network_credential_secret(secret.id, actor: @system_actor)

    assert_ciphertext_and_audits_are_redacted!(secret.id, password_marker)
  end

  defp credential_manager!(suffix) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Credential rotation profile #{suffix}",
          description: "Current-authority fixture for credential rotation",
          permissions: [@credential_permission]
        },
        actor: @system_actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!(actor: @system_actor)

    User
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:password, "rotation-test-password-#{suffix}")
    |> Ash.Changeset.for_create(
      :create,
      %{
        email: "credential-rotation-#{suffix}@serviceradar.local",
        display_name: "Credential rotation #{suffix}",
        role: :viewer,
        role_profile_id: profile.id
      },
      actor: @system_actor
    )
    |> Ash.create!(actor: @system_actor)
  end

  defp human_actor(user) do
    %{
      id: user.id,
      role: user.role,
      permissions: MapSet.new([@credential_permission])
    }
  end

  defp approved_descriptor_fixture!(plugin_id, provider) do
    manifest = %{
      "id" => plugin_id,
      "name" => "Credential rotation DB fixture",
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      },
      "integrations" => %{
        "credential_profiles" => [rotation_profile(provider)],
        "inventory_sources" => []
      }
    }

    Plugin
    |> Ash.Changeset.for_create(
      :create,
      %{plugin_id: plugin_id, name: "Credential rotation DB fixture"},
      actor: @system_actor
    )
    |> Ash.create!(actor: @system_actor)

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Credential rotation DB fixture",
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}",
          signature: %{}
        },
        actor: @system_actor
      )
      |> Ash.create!(actor: @system_actor)

    package
    |> Ash.Changeset.for_update(:approve, %{approved_by: "credential-rotation-db-test"},
      actor: @system_actor
    )
    |> Ash.update!(actor: @system_actor)
  end

  defp rotation_profile(provider) do
    %{
      "provider" => provider,
      "label" => "Credential rotation DB fixture",
      "auth_methods" => [
        %{
          "id" => "username_password",
          "label" => "Username and password",
          "credential_kind" => "username_password",
          "fields" => [
            %{
              "id" => "username",
              "label" => "Username",
              "control" => "text",
              "required" => true,
              "secret" => false,
              "public" => true
            },
            %{
              "id" => "password",
              "label" => "Password",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            }
          ],
          "payload" => %{
            "format" => "scalar",
            "field" => "password",
            "username_field" => "username"
          }
        }
      ],
      "purposes" => ["configuration_read"],
      "scope_types" => ["agent"],
      "supports_rules" => false,
      "provisioning" => %{"mode" => "credential_only"}
    }
  end

  defp assert_ciphertext_and_audits_are_redacted!(secret_id, marker) do
    dumped_id = Ecto.UUID.dump!(secret_id)

    %{rows: [[ciphertext]]} =
      SQL.query!(
        Repo,
        "SELECT encode(encrypted_secret_payload, 'base64') FROM platform.network_credential_secrets WHERE id = $1",
        [dumped_id]
      )

    %{rows: [[versions]]} =
      SQL.query!(
        Repo,
        "SELECT coalesce(string_agg(to_jsonb(version)::text, ''), '') FROM platform.network_credential_secret_versions version WHERE version_source_id = $1",
        [dumped_id]
      )

    %{rows: [[lifecycle_events, actions]]} =
      SQL.query!(
        Repo,
        """
        SELECT
          coalesce(string_agg(to_jsonb(event)::text, ''), ''),
          coalesce(array_agg(event.unmapped->>'action'), ARRAY[]::text[])
        FROM platform.ocsf_events event
        WHERE event.unmapped->>'network_credential_secret_id' = $1
        """,
        [to_string(secret_id)]
      )

    refute ciphertext =~ marker
    refute versions =~ marker
    refute lifecycle_events =~ marker
    assert "start_rotation" in actions
    assert "complete_rotation" in actions
  end
end
