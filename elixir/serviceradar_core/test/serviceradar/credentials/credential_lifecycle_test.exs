defmodule ServiceRadar.Credentials.CredentialLifecycleTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialEventWriter
  alias ServiceRadar.Credentials.CredentialSecretProvider
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @moduletag :requires_app

  @credential_manager %{
    id: "user-1",
    role: :admin,
    permissions: MapSet.new(["settings.credentials.manage"])
  }

  @viewer %{id: "user-2", role: :viewer, permissions: MapSet.new([])}
  @system_actor SystemActor.system(:credential_lifecycle_test)

  test "credential provider lifecycle uses explicit state-machine actions" do
    actions = CredentialSecretProvider |> Info.actions() |> Enum.map(& &1.name)

    assert :enable in actions
    assert :disable in actions
    assert :record_test_success in actions
    assert :record_test_failure in actions
    assert :record_test_unavailable in actions

    refute :mark_degraded in actions
    refute :mark_unavailable in actions
  end

  test "credential rotation is a first-class state machine and not generic update input" do
    actions = NetworkCredentialSecret |> Info.actions() |> Enum.map(& &1.name)
    update_action = Info.action(NetworkCredentialSecret, :update)

    assert :mark_rotation_due in actions
    assert :start_rotation in actions
    assert :complete_rotation in actions
    assert :fail_rotation in actions
    assert :disable_rotation in actions
    assert :enable_rotation in actions

    refute :rotation_state in update_action.accept
    refute :rotation_started_at in update_action.accept
    refute :last_rotation_failed_at in update_action.accept
  end

  test "credential resources require credential management permission" do
    assert Ash.can?({CredentialSecretProvider, :read}, @credential_manager)

    assert ActorHasPermission.match?(
             @credential_manager,
             [permission: "settings.credentials.manage"],
             %{}
           )

    refute ActorHasPermission.match?(@viewer, [permission: "settings.credentials.manage"], %{})

    assert Ash.can?({NetworkCredentialSecret, :create}, @credential_manager)
  end

  test "credential rule integration and controller scope is generated and immutable" do
    integration = Info.attribute(NetworkCredentialRule, :integration_id)
    controller = Info.attribute(NetworkCredentialRule, :controller_id)

    assert integration.allow_nil? == false
    assert controller.allow_nil? == false
    assert is_function(integration.default, 0)
    assert is_function(controller.default, 0)

    for action_name <- [:create, :update], field <- [:integration_id, :controller_id] do
      refute field in Info.action(NetworkCredentialRule, action_name).accept
    end
  end

  test "resolution audit creation is system-only while credential managers can read" do
    assert Ash.can?({CredentialSecretResolutionAudit, :read}, @credential_manager)

    refute Ash.can?({CredentialSecretResolutionAudit, :create}, @credential_manager)

    assert Ash.can?({CredentialSecretResolutionAudit, :create}, @system_actor)
  end

  test "credential resolution events are redacted" do
    attrs =
      CredentialEventWriter.secret_resolution_event_attrs(%{
        secret_id: "secret-1",
        secret_provider_id: "provider-1",
        grant_id: "grant-1",
        consumer_kind: :northbound_action,
        consumer_id: "task-1",
        purpose: "device-task-api-call",
        target_kind: "device",
        target_id: "dev-1",
        resolution_location: :agent,
        outcome: :success,
        cache_status: :disabled,
        metadata: %{"external_secret_ref" => "path/to/secret", "token" => "secret-token"}
      })

    rendered = inspect(attrs)

    assert attrs.severity == "Informational"
    assert attrs.log_name == "credential.secret_resolution"
    assert rendered =~ "secret-1"
    refute rendered =~ "secret-token"
    refute rendered =~ "path/to/secret"
  end
end
