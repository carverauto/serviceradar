defmodule ServiceRadar.Credentials.CredentialBrokerGrantTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.RequestBodyPolicy
  alias ServiceRadar.Credentials.SecretBroker

  @moduletag :requires_app

  @secret_id "018f3f56-1111-7222-8333-123456789abc"

  test "grant resource is state-machine backed and system issued" do
    actions = CredentialBrokerGrant |> Info.actions() |> Enum.map(& &1.name)

    assert :issue in actions
    assert :activate in actions
    assert :consume in actions
    assert :deny in actions
    assert :expire in actions
    assert :revoke in actions

    manager = %{
      id: "user-1",
      role: :admin,
      permissions: MapSet.new(["settings.credentials.manage"])
    }

    system = SystemActor.system(:credential_broker_grant_test)

    assert Ash.can?({CredentialBrokerGrant, :read}, manager)
    refute Ash.can?({CredentialBrokerGrant, :issue}, manager)
    assert Ash.can?({CredentialBrokerGrant, :issue}, system)
  end

  test "issue_attrs calculates expiry and secret ref without plaintext" do
    now = ~U[2026-05-21 12:00:00Z]

    attrs =
      CredentialBrokerGrant.issue_attrs(
        %{
          secret_id: @secret_id,
          grant_type: "awx_oauth2_token",
          consumer_kind: :ansible,
          consumer_id: "controller-1",
          purpose: "awx.launch_job",
          target_kind: "awx_controller",
          target_id: "controller-1",
          agent_id: "agent-a",
          resolution_location: :agent,
          ttl_seconds: 120
        },
        now
      )

    assert attrs.secret_ref == "credentialref:network-credential-secret:#{@secret_id}"
    assert attrs.expires_at == ~U[2026-05-21 12:02:00Z]
    refute inspect(attrs) =~ "Bearer "
    refute Map.has_key?(attrs, :secret_payload)
  end

  test "issue_attrs derives secret id from a canonical stored reference" do
    attrs =
      CredentialBrokerGrant.issue_attrs(%{
        secret_ref: "credentialref:network-credential-secret:#{@secret_id}",
        grant_type: "producer_schedule_credential",
        consumer_kind: :plugin,
        purpose: "device_inventory"
      })

    assert attrs.secret_id == @secret_id
    assert attrs.secret_ref == "credentialref:network-credential-secret:#{@secret_id}"

    unrelated =
      CredentialBrokerGrant.issue_attrs(%{
        secret_ref: "credentialref:example:service-account",
        grant_type: "producer_schedule_credential",
        consumer_kind: :plugin,
        purpose: "device_inventory"
      })

    refute Map.has_key?(unrelated, :secret_id)

    malformed =
      CredentialBrokerGrant.issue_attrs(%{
        secret_ref: "credentialref:network-credential-secret:not-a-uuid",
        grant_type: "producer_schedule_credential",
        consumer_kind: :plugin,
        purpose: "device_inventory"
      })

    refute Map.has_key?(malformed, :secret_id)
  end

  test "payload preserves existing wire contract while adding scope" do
    payload =
      CredentialBrokerGrant.to_payload(%{
        id: "grant-1",
        secret_id: @secret_id,
        secret_ref: "credentialref:network-credential-secret:#{@secret_id}",
        grant_type: "awx_oauth2_token",
        consumer_kind: :ansible,
        consumer_id: "controller-1",
        purpose: "awx.launch_job",
        target_kind: "awx_controller",
        target_id: "controller-1",
        agent_id: "agent-a",
        resolution_location: :agent,
        inject: %{"type" => "http_header", "name" => "Authorization", "scheme" => "Bearer"},
        allowed_schemes: ["https"],
        allowed_methods: ["POST"],
        allowed_paths: ["/api/v2/"],
        ttl_seconds: 300
      })

    assert payload["schema"] == CredentialBrokerGrant.schema()
    assert payload["grant_id"] == "grant-1"

    assert payload["credential_secret_ref"] ==
             "credentialref:network-credential-secret:#{@secret_id}"

    assert payload["consumer"] == %{
             "kind" => "ansible",
             "id" => "controller-1",
             "purpose" => "awx.launch_job"
           }

    assert payload["target"] == %{
             "kind" => "awx_controller",
             "id" => "controller-1",
             "agent_id" => "agent-a"
           }

    assert payload["allow"] == %{
             "schemes" => ["https"],
             "methods" => ["POST"],
             "paths" => ["/api/v2/"]
           }
  end

  test "payload derives expiry for non-persisted attrs" do
    payload =
      CredentialBrokerGrant.to_payload(%{
        secret_id: @secret_id,
        secret_ref: "credentialref:network-credential-secret:#{@secret_id}",
        grant_type: "awx_oauth2_token",
        consumer_kind: :ansible,
        consumer_id: "controller-1",
        purpose: "awx.launch_job",
        resolution_location: :agent,
        ttl_seconds: 120
      })

    refute Map.has_key?(payload, "grant_id")
    assert {:ok, expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
    assert DateTime.after?(expires_at, DateTime.utc_now())
  end

  test "body-bound grants use v2 and carry only the typed policy in the allow envelope" do
    body = ~s({"limit":"node-1"})

    attrs =
      CredentialBrokerGrant.issue_attrs(%{
        id: "grant-1",
        secret_id: @secret_id,
        grant_type: "awx_oauth2_token",
        consumer_kind: :ansible,
        consumer_id: "controller-1",
        purpose: "awx.launch_job",
        resolution_location: :agent,
        allowed_methods: ["POST"],
        allowed_paths: ["=/api/v2/job_templates/42/launch/"],
        request_body_policy: RequestBodyPolicy.bound_bytes(body, max_bytes: 256 * 1024)
      })

    payload = CredentialBrokerGrant.to_payload(attrs)

    assert payload["schema"] == CredentialBrokerGrant.body_bound_schema()
    assert payload["allow"]["request_body"]["mode"] == "bound_bytes"
    assert payload["allow"]["request_body"]["source"] == RequestBodyPolicy.bound_body_source()
    refute inspect(payload["allow"]["request_body"]) =~ body
  end

  test "invalid body policies fail closed before wire serialization" do
    assert_raise ArgumentError, fn ->
      CredentialBrokerGrant.to_payload(%{
        secret_ref: "credentialref:network-credential-secret:#{@secret_id}",
        grant_type: "awx_oauth2_token",
        consumer_kind: :ansible,
        purpose: "awx.launch_job",
        request_body_policy: %{
          "mode" => "bound_bytes",
          "sha256" => "not-a-digest",
          "source" => "plugin.body",
          "content_type" => "application/json",
          "max_bytes" => 1024,
          "max_mutations" => 1
        }
      })
    end
  end

  test "grant validation enforces scope and expiry" do
    grant = %{
      id: "grant-1",
      secret_id: @secret_id,
      status: :active,
      consumer_kind: :device_task,
      consumer_id: "task-1",
      purpose: "device-task-api-call",
      target_kind: "device",
      target_id: "dev-1",
      agent_id: "agent-a",
      resolution_location: :agent,
      expires_at: ~U[2026-05-21 12:05:00Z]
    }

    assert :ok =
             CredentialBrokerGrant.validate_loaded_grant(grant,
               secret_id: @secret_id,
               consumer_kind: :device_task,
               consumer_id: "task-1",
               purpose: "device-task-api-call",
               target_kind: "device",
               target_id: "dev-1",
               agent_id: "agent-a",
               resolution_location: :agent,
               now: ~U[2026-05-21 12:00:00Z]
             )

    assert {:error, {:grant_scope_mismatch, :target_id}} =
             CredentialBrokerGrant.validate_loaded_grant(grant,
               target_id: "dev-2",
               now: ~U[2026-05-21 12:00:00Z]
             )

    assert {:error, :grant_expired} =
             CredentialBrokerGrant.validate_loaded_grant(grant, now: ~U[2026-05-21 12:06:00Z])
  end

  test "secret broker validates grants before resolving already loaded secrets" do
    secret = %{
      id: @secret_id,
      source_type: :internal_encrypted,
      provider: "awx",
      credential_kind: :api_token,
      secret_payload: "token-value"
    }

    grant = %{
      id: "grant-1",
      secret_id: @secret_id,
      status: :active,
      consumer_kind: :device_task,
      consumer_id: "task-1",
      purpose: "device-task-api-call",
      target_kind: "device",
      target_id: "dev-1",
      resolution_location: :agent,
      expires_at: ~U[2026-05-21 12:05:00Z]
    }

    assert {:ok, resolved} =
             SecretBroker.resolve_loaded_secret_with_grant(secret, grant,
               consumer_kind: :device_task,
               consumer_id: "task-1",
               target_id: "dev-1",
               now: ~U[2026-05-21 12:00:00Z]
             )

    assert resolved.value == "token-value"

    assert {:error, {:grant_scope_mismatch, :target_id}} =
             SecretBroker.resolve_loaded_secret_with_grant(secret, grant,
               target_id: "dev-2",
               now: ~U[2026-05-21 12:00:00Z]
             )
  end
end
