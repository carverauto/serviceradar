defmodule ServiceRadar.Credentials.CredentialRotationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRotation
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @secret_id "01900000-0000-7000-8000-000000000001"
  @permission "settings.credentials.manage"

  test "reauthorizes, reloads, resolves internally, and builds before changing lifecycle state" do
    caller = %{user: %{id: "stale-user"}, permissions: MapSet.new([@permission])}
    current_user = %{id: "current-user", email: "admin@example.test", role: :admin}
    current_permissions = MapSet.new([@permission])
    secret = rotatable_secret()

    stale_secret =
      secret
      |> Map.put(:provider, "forged-provider")
      |> Map.put(:metadata, %{"auth_method" => "forged-method"})

    profile = CredentialIntegrationFixtures.target_policy_profile()
    attrs = rotation_attrs()
    started = Map.put(secret, :rotation_state, :rotating)
    completed = Map.put(secret, :public_fingerprint, attrs.public_fingerprint)
    test_pid = self()

    dependencies = %{
      authorize: fn subject, permission ->
        send(test_pid, {:authorize, subject, permission})
        {:ok, %{user: current_user, permissions: current_permissions}}
      end,
      load_secret: fn id, actor ->
        send(test_pid, {:load_secret, id, actor})
        {:ok, secret}
      end,
      profile_for: fn provider, actor ->
        send(test_pid, {:profile_for, provider, actor})
        {:ok, profile}
      end,
      build_rotation: fn loaded_secret, fresh_profile, submitted_values, opts ->
        send(
          test_pid,
          {:build_rotation, loaded_secret, fresh_profile, submitted_values, opts}
        )

        {:ok, attrs}
      end,
      start_rotation: fn loaded_secret, actor ->
        send(test_pid, {:start_rotation, loaded_secret, actor})
        {:ok, started}
      end,
      complete_rotation: fn rotating_secret, rotation_attrs, actor ->
        send(test_pid, {:complete_rotation, rotating_secret, rotation_attrs, actor})
        {:ok, completed}
      end,
      fail_rotation: fn _rotating_secret, _failure_code, _actor ->
        flunk("successful rotation must not record failure")
      end,
      reload_secret: fn id, actor ->
        send(test_pid, {:reload_secret, id, actor})
        {:ok, completed}
      end
    }

    submitted = %{"username" => "operator", "password" => "replacement-secret"}

    assert {:ok, ^completed} =
             CredentialRotation.rotate(stale_secret, submitted, caller,
               dependencies: dependencies
             )

    assert_receive {:authorize, ^caller, @permission}
    assert_receive {:load_secret, @secret_id, authorized_actor}
    assert authorized_actor.id == current_user.id
    assert authorized_actor.permissions == current_permissions

    assert_receive {:profile_for, "example-network", catalog_actor}
    assert catalog_actor.role == :system
    refute catalog_actor.id == authorized_actor.id

    assert_receive {:build_rotation, ^secret, ^profile, ^submitted, []}
    assert_receive {:start_rotation, ^secret, lifecycle_actor}
    assert lifecycle_actor.role == :system
    refute lifecycle_actor.id in [authorized_actor.id, catalog_actor.id]
    assert_receive {:complete_rotation, ^started, ^attrs, ^lifecycle_actor}
    assert_receive {:reload_secret, @secret_id, ^authorized_actor}
  end

  test "validation failure occurs before start and returns only a bounded safe reason" do
    marker = "submitted-secret-must-not-escape-validation"
    test_pid = self()

    dependencies =
      dependencies(%{
        build_rotation: fn _secret, _profile, _submitted_values, _opts ->
          send(test_pid, :built)
          {:error, {:missing_credential_field, "password"}}
        end,
        start_rotation: fn _secret, _actor ->
          send(test_pid, :started)
          {:ok, %{}}
        end
      })

    result =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"username" => "operator", "password" => marker},
        caller(),
        dependencies: dependencies
      )

    assert result == {:error, {:missing_credential_field, "password"}}
    assert_receive :built
    refute_receive :started
    refute inspect(result) =~ marker
  end

  test "completion failure records a bounded redacted failure code" do
    marker = "completion-error-secret-marker"
    test_pid = self()
    started = Map.put(rotatable_secret(), :rotation_state, :rotating)

    dependencies =
      dependencies(%{
        start_rotation: fn _secret, _actor -> {:ok, started} end,
        complete_rotation: fn _secret, _attrs, _actor ->
          {:error, {:provider_rejected, marker}}
        end,
        fail_rotation: fn failed_secret, failure_code, actor ->
          send(test_pid, {:failed, failed_secret, failure_code, actor})
          {:ok, Map.put(failed_secret, :rotation_state, :rotation_failed)}
        end,
        reload_secret: fn _id, _actor ->
          flunk("failed rotation must not report a successful reload")
        end
      })

    result =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"username" => "operator", "password" => marker},
        caller(),
        dependencies: dependencies
      )

    assert result == {:error, :credential_rotation_failed}
    assert_receive {:failed, ^started, "rotation_complete_failed", actor}
    assert actor.role == :system
    refute inspect(result) =~ marker
    refute inspect(actor) =~ marker
  end

  test "failure-transition errors return a distinct bounded recovery error" do
    marker = "failure-transition-secret-marker"
    test_pid = self()
    started = Map.put(rotatable_secret(), :rotation_state, :rotating)

    dependencies =
      dependencies(%{
        start_rotation: fn _secret, _actor -> {:ok, started} end,
        complete_rotation: fn _secret, _attrs, _actor ->
          {:error, {:provider_rejected, marker}}
        end,
        fail_rotation: fn failed_secret, failure_code, actor ->
          send(test_pid, {:recovery_failed, failed_secret, failure_code, actor})
          {:error, {:database_rejected, marker}}
        end
      })

    result =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"username" => "operator", "password" => marker},
        caller(),
        dependencies: dependencies
      )

    assert result == {:error, :credential_rotation_recovery_failed}
    assert_receive {:recovery_failed, ^started, "rotation_complete_failed", actor}
    assert actor.role == :system
    refute inspect(result) =~ marker
    refute inspect(actor) =~ marker
  end

  test "fresh authority denial and a stale secret both fail before catalog resolution" do
    marker = "untrusted-error-secret-marker"
    test_pid = self()

    denied_dependencies =
      dependencies(%{
        authorize: fn _subject, _permission -> {:error, {:denied, marker}} end,
        load_secret: fn _id, _actor ->
          send(test_pid, :loaded_after_denial)
          {:ok, rotatable_secret()}
        end
      })

    denied =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"password" => marker},
        caller(),
        dependencies: denied_dependencies
      )

    assert denied == {:error, :credential_rotation_forbidden}
    refute_receive :loaded_after_denial
    refute inspect(denied) =~ marker

    stale_dependencies =
      dependencies(%{
        load_secret: fn _id, _actor -> {:error, {:database_error, marker}} end,
        profile_for: fn _provider, _actor ->
          send(test_pid, :catalog_after_stale_load)
          {:ok, CredentialIntegrationFixtures.target_policy_profile()}
        end
      })

    stale =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"password" => marker},
        caller(),
        dependencies: stale_dependencies
      )

    assert stale == {:error, :credential_not_found}
    refute_receive :catalog_after_stale_load
    refute inspect(stale) =~ marker
  end

  test "start failure does not claim the credential reached rotating state" do
    marker = "start-error-secret-marker"
    test_pid = self()

    dependencies =
      dependencies(%{
        start_rotation: fn _secret, _actor -> {:error, {:conflict, marker}} end,
        complete_rotation: fn _secret, _attrs, _actor ->
          send(test_pid, :completed_after_start_failure)
          {:ok, %{}}
        end,
        fail_rotation: fn _secret, _failure_code, _actor ->
          send(test_pid, :failed_without_rotating)
          {:ok, %{}}
        end
      })

    result =
      CredentialRotation.rotate(
        rotatable_secret(),
        %{"username" => "operator", "password" => marker},
        caller(),
        dependencies: dependencies
      )

    assert result == {:error, :credential_rotation_start_failed}
    refute_receive :completed_after_start_failure
    refute_receive :failed_without_rotating
    refute inspect(result) =~ marker
  end

  defp dependencies(overrides) do
    secret = rotatable_secret()
    profile = CredentialIntegrationFixtures.target_policy_profile()
    attrs = rotation_attrs()
    current_user = %{id: "current-user", email: "admin@example.test", role: :admin}
    permissions = MapSet.new([@permission])

    Map.merge(
      %{
        authorize: fn _subject, @permission ->
          {:ok, %{user: current_user, permissions: permissions}}
        end,
        load_secret: fn @secret_id, _actor -> {:ok, secret} end,
        profile_for: fn "example-network", %{role: :system} -> {:ok, profile} end,
        build_rotation: fn ^secret, ^profile, _submitted_values, [] -> {:ok, attrs} end,
        start_rotation: fn ^secret, _actor ->
          {:ok, Map.put(secret, :rotation_state, :rotating)}
        end,
        complete_rotation: fn started, ^attrs, _actor ->
          {:ok, Map.put(started, :rotation_state, :active)}
        end,
        fail_rotation: fn started, _failure_code, _actor ->
          {:ok, Map.put(started, :rotation_state, :rotation_failed)}
        end,
        reload_secret: fn @secret_id, _actor -> {:ok, secret} end
      },
      overrides
    )
  end

  defp caller do
    %{user: %{id: "stale-user"}, permissions: MapSet.new([@permission])}
  end

  defp rotatable_secret do
    %{
      id: @secret_id,
      provider: "example-network",
      credential_kind: :username_password,
      source_type: :internal_encrypted,
      rotation_state: :active,
      next_rotation_due_at: nil,
      metadata: %{
        "credential_descriptor" => "package_manifest.v1",
        "auth_method" => "username_password"
      }
    }
  end

  defp rotation_attrs do
    %{
      secret_payload: "replacement-secret",
      username: "operator",
      public_fingerprint: "sha256:replacement",
      metadata: %{
        "credential_descriptor" => "package_manifest.v1",
        "auth_method" => "username_password"
      },
      next_rotation_due_at: nil
    }
  end
end
