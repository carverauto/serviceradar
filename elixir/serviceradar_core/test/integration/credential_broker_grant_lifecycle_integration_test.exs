defmodule ServiceRadar.Credentials.CredentialBrokerGrantLifecycleIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Monitoring.OcsfEvent
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "agent broker resolution expires stale grants and emits a lifecycle event" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "expired-grant-secret-#{unique}",
          provider: "test",
          credential_kind: :api_token,
          source_type: :internal_encrypted,
          secret_payload: "token-value-#{unique}",
          metadata: %{"test" => "credential_broker_grant_lifecycle"}
        },
        actor: actor
      )

    expires_at =
      DateTime.utc_now()
      |> DateTime.shift(minute: -1)
      |> DateTime.truncate(:second)

    {:ok, grant} =
      CredentialBrokerGrant.issue_grant(
        CredentialBrokerGrant.issue_attrs(%{
          secret_id: secret.id,
          grant_type: "integration_test",
          consumer_kind: :device_task,
          consumer_id: "task-#{unique}",
          purpose: "device-task-api-call",
          target_kind: "device",
          target_id: "device-#{unique}",
          agent_id: "agent-#{unique}",
          resolution_location: :agent,
          inject: %{
            "type" => "http_header",
            "name" => "Authorization",
            "scheme" => "Bearer"
          },
          metadata: %{"controller_id" => "awx-#{unique}"},
          ttl_seconds: 1,
          expires_at: expires_at
        }),
        actor: actor
      )

    assert %{rows: [[action_inputs]]} =
             Repo.query!(
               """
               SELECT version_action_inputs
               FROM platform.credential_broker_grant_versions
               WHERE version_source_id = ($1::text)::uuid
                 AND version_action_name = 'issue'
               ORDER BY version_inserted_at DESC
               LIMIT 1
               """,
               [grant.id]
             )

    assert get_in(action_inputs, ["inject", "scheme"]) == "Bearer"
    assert get_in(action_inputs, ["metadata", "controller_id"]) == "awx-#{unique}"

    assert {:error, :grant_expired} =
             AgentGatewaySync.resolve_credential_broker_grant(%{
               "agent_id" => grant.agent_id,
               "grant_id" => grant.id,
               "credential_secret_ref" => grant.secret_ref,
               "consumer_kind" => "device_task",
               "consumer_id" => grant.consumer_id,
               "purpose" => grant.purpose
             })

    assert {:ok, expired_grant} = CredentialBrokerGrant.get_by_id(grant.id, actor: actor)
    assert expired_grant.status == :expired

    # Lifecycle events are published from the grant action's transaction, so
    # they wait in the publish outbox until it commits; deliver them.
    Oban.drain_queue(queue: :events)

    events = credential_broker_grant_events(actor, grant.id)
    actions = Enum.map(events, &get_in(&1.unmapped || %{}, ["action"]))

    refute "issue" in actions

    assert Enum.any?(events, fn event ->
             event.log_name == "credential.broker_grant.lifecycle" and
               get_in(event.unmapped || %{}, ["event_family"]) ==
                 "credential_broker_grant_lifecycle" and
               get_in(event.unmapped || %{}, ["credential_broker_grant_id"]) ==
                 to_string(grant.id) and
               get_in(event.unmapped || %{}, ["action"]) == "expire" and
               get_in(event.unmapped || %{}, ["status"]) == "expired"
           end)
  end

  test "resolve_with_grant resolves the secret named by a grant that carries only a reference" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    secret =
      CredentialIntegrationFixtures.secret!(
        actor: actor,
        secret_payload: "token-from-ref-#{unique}"
      )

    grant = %{
      id: "grant-#{unique}",
      secret_ref: SecretRefs.network_credential_ref(to_string(secret.id)),
      status: :issued,
      resolution_location: :agent,
      expires_at: DateTime.shift(DateTime.utc_now(), minute: 1)
    }

    assert {:ok, resolved} = SecretBroker.resolve_with_grant(grant, actor: actor)
    assert resolved.value == "token-from-ref-#{unique}"
  end

  test "resolve_with_grant refuses scope mismatch and inactive grants and audits each denial" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    secret =
      CredentialIntegrationFixtures.secret!(
        actor: actor,
        secret_payload: "scoped-token-#{unique}"
      )

    grant = %{
      id: "grant-#{unique}",
      secret_id: to_string(secret.id),
      status: :active,
      consumer_kind: :device_task,
      consumer_id: "task-#{unique}",
      purpose: "device-task-api-call",
      target_kind: "device",
      target_id: "device-#{unique}",
      resolution_location: :agent,
      expires_at: DateTime.shift(DateTime.utc_now(), minute: 1)
    }

    assert {:ok, resolved} =
             SecretBroker.resolve_with_grant(grant, actor: actor, target_id: grant.target_id)

    assert resolved.value == "scoped-token-#{unique}"

    assert {:error, {:grant_scope_mismatch, :target_id}} =
             SecretBroker.resolve_with_grant(grant,
               actor: actor,
               target_id: "device-other-#{unique}"
             )

    assert {:error, {:grant_not_active, :revoked}} =
             SecretBroker.resolve_with_grant(%{grant | status: :revoked},
               actor: actor,
               target_id: grant.target_id
             )

    # Neither call asked for audit?: a refused grant is audited regardless, with
    # the scope the caller requested and the reason it was refused.
    assert {:ok, audits} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: actor)

    denials = Enum.filter(audits, &(&1.outcome == :denied))
    assert length(denials) == 2

    mismatch = Enum.find(denials, &(&1.metadata["denial_reason"] == "grant_scope_mismatch"))
    assert mismatch.grant_id == grant.id
    assert mismatch.error_class == :provider_policy_denied
    assert mismatch.metadata["denied_field"] == "target_id"
    assert mismatch.consumer_kind == :device_task
    assert mismatch.consumer_id == grant.consumer_id
    assert mismatch.target_id == "device-other-#{unique}"
    assert mismatch.resolution_location == :agent

    inactive = Enum.find(denials, &(&1.metadata["denial_reason"] == "grant_not_active"))
    assert inactive.grant_id == grant.id
    assert inactive.error_class == :provider_policy_denied
    assert inactive.metadata["grant_status"] == "revoked"
    assert inactive.target_id == grant.target_id
  end

  # The agent sends the resolved value verbatim after `PVEAPIToken=`. A Proxmox
  # secret that stores only the token secret has to come back joined with its
  # token id, and a secret that already stores the whole token must keep it.
  test "agent broker resolution returns a complete Proxmox token for both stored shapes" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])

    bare =
      proxmox_secret!(actor, unique, "bare", "11111111-aaaa-4bbb-8ccc-#{unique}",
        username: "svc@pve",
        metadata: %{"token_id" => "svc@pve!inventory"}
      )

    full =
      proxmox_secret!(
        actor,
        unique,
        "full",
        "svc@pve!inventory=22222222-dddd-4eee-8fff-#{unique}",
        username: "svc"
      )

    assert {:ok, %{value: bare_value}} = resolve_for_agent(actor, bare, unique)
    assert bare_value == "svc@pve!inventory=11111111-aaaa-4bbb-8ccc-#{unique}"

    assert {:ok, %{value: full_value}} = resolve_for_agent(actor, full, unique)
    assert full_value == "svc@pve!inventory=22222222-dddd-4eee-8fff-#{unique}"
  end

  defp proxmox_secret!(actor, unique, label, payload, attrs) do
    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        Map.merge(
          %{
            name: "proxmox-#{label}-#{unique}",
            provider: "proxmox",
            credential_kind: :api_token,
            source_type: :internal_encrypted,
            secret_payload: payload
          },
          Map.new(attrs)
        ),
        actor: actor
      )

    secret
  end

  defp resolve_for_agent(actor, secret, unique) do
    {:ok, grant} =
      CredentialBrokerGrant.issue_grant(
        CredentialBrokerGrant.issue_attrs(%{
          secret_id: secret.id,
          grant_type: "integration_test",
          consumer_kind: :plugin,
          consumer_id: "plugin-#{unique}-#{secret.id}",
          purpose: "proxmox-inventory",
          target_kind: "device",
          target_id: "device-#{unique}",
          agent_id: "agent-#{unique}",
          resolution_location: :agent,
          inject: %{
            "type" => "http_header",
            "name" => "Authorization",
            "scheme" => "PVEAPIToken"
          },
          ttl_seconds: 300
        }),
        actor: actor
      )

    AgentGatewaySync.resolve_credential_broker_grant(%{
      "agent_id" => grant.agent_id,
      "grant_id" => grant.id,
      "credential_secret_ref" => grant.secret_ref,
      "consumer_kind" => "plugin",
      "consumer_id" => grant.consumer_id,
      "purpose" => grant.purpose
    })
  end

  test "reuse_or_issue reuses only a live grant of identical scope from a still-issuable rule" do
    actor = SystemActor.system(:credential_broker_grant_lifecycle_test)
    unique = System.unique_integer([:positive])
    secret = CredentialIntegrationFixtures.secret!(actor: actor)

    {:ok, rule} =
      NetworkCredentialRule.create_rule(
        %{
          name: "reuse-rule-#{unique}",
          provider: "example-network",
          auth_method: "api_token",
          purpose: "inventory",
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: "agent-#{unique}",
          secret_id: secret.id
        },
        actor: actor
      )

    # The shape the plugin assignment materializer builds every reconcile.
    attrs = %{
      secret_id: secret.id,
      credential_rule_id: rule.id,
      grant_type: "plugin_credential",
      consumer_kind: :plugin,
      consumer_id: "example-plugin",
      purpose: "inventory",
      agent_id: "agent-#{unique}",
      resolution_location: :agent,
      inject: %{"type" => "http_header", "name" => "Authorization", "scheme" => "Bearer"},
      allowed_methods: ["GET"],
      allowed_hosts: ["host01.example.com"],
      allowed_ports: [8006],
      ttl_seconds: 300
    }

    assert {:ok, first} = CredentialBrokerGrant.reuse_or_issue(attrs, actor: actor)
    assert {:ok, again} = CredentialBrokerGrant.reuse_or_issue(attrs, actor: actor)
    assert again.id == first.id
    assert [_one] = live_grants(actor, attrs)

    for {label, changed} <- [
          {"allow-list", %{attrs | allowed_hosts: ["host02.example.com"]}},
          {"purpose", %{attrs | purpose: "console"}},
          {"inject", put_in(attrs, [:inject, "scheme"], "PVEAPIToken")}
        ] do
      assert {:ok, other} = CredentialBrokerGrant.reuse_or_issue(changed, actor: actor)
      refute other.id == first.id, "a different #{label} reused the grant"
    end

    assert {:ok, outlives_ttl} =
             CredentialBrokerGrant.reuse_or_issue(attrs,
               actor: actor,
               min_remaining_seconds: 400
             )

    refute outlives_ttl.id == first.id

    assert {:ok, _disabled} =
             NetworkCredentialRule.update_rule(rule, %{enabled: false}, actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             CredentialBrokerGrant.reuse_or_issue(attrs, actor: actor)
  end

  defp live_grants(actor, attrs) do
    {:ok, grants} =
      CredentialBrokerGrant.list_live_for_scope(
        %{
          agent_id: attrs.agent_id,
          consumer_kind: attrs.consumer_kind,
          consumer_id: attrs.consumer_id,
          secret_id: attrs.secret_id,
          expires_after: DateTime.utc_now()
        },
        actor: actor
      )

    Enum.filter(grants, &(&1.purpose == attrs.purpose))
  end

  defp credential_broker_grant_events(actor, grant_id) do
    OcsfEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn event ->
      get_in(event.unmapped || %{}, ["credential_broker_grant_id"]) == to_string(grant_id)
    end)
  end
end
