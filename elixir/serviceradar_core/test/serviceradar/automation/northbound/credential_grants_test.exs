defmodule ServiceRadar.Automation.Northbound.CredentialGrantsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionInvocation
  alias ServiceRadar.Automation.Northbound.ActionInvocationTarget
  alias ServiceRadar.Automation.Northbound.ActionProvider
  alias ServiceRadar.Automation.Northbound.CredentialGrants
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.PluginAssignment

  @secret_id "018f3f56-1111-7222-8333-123456789abc"

  defmodule FakeGrantIssuer do
    @moduledoc false

    def issue(attrs, opts) do
      send(opts[:test_pid], {:grant_attrs, attrs})

      attrs =
        attrs
        |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 12:00:00Z])
        |> Map.put(:id, "grant-#{attrs.purpose}")

      {:ok, CredentialBrokerGrant.to_payload(attrs)}
    end
  end

  test "prepare_launch issues broker grants from invocation-selected descriptor requirements" do
    invocation =
      invocation(%{
        descriptor:
          descriptor(%{
            credential_requirements: %{
              "credentials" => [
                %{
                  "name" => "api",
                  "credential_secret_input" => "api_secret_id",
                  "grant_type" => "http_api_callout",
                  "purpose" => "device-api-call",
                  "allow" => %{
                    "methods" => ["GET", "POST"],
                    "paths" => ["/api/v1/"],
                    "hosts" => ["device.example.com"],
                    "ports" => "443,8443"
                  },
                  "inject" => %{
                    "type" => "http_header",
                    "name" => "Authorization",
                    "scheme" => "Bearer"
                  }
                }
              ]
            }
          }),
        input_values: %{"api_secret_id" => @secret_id},
        target_snapshots: [%{"device_uid" => "device-1"}]
      })

    assert {:ok, prepared} =
             CredentialGrants.prepare_launch(invocation, assignment(),
               grant_issuer: {FakeGrantIssuer, :issue},
               test_pid: self()
             )

    assert_receive {:grant_attrs, attrs}

    assert attrs.secret_id == @secret_id
    assert attrs.consumer_kind == :northbound_action
    assert attrs.consumer_id == "invocation-1"
    assert attrs.purpose == "device-api-call"
    assert attrs.target_kind == "device"
    assert attrs.target_id == "device-1"
    assert attrs.agent_id == "agent-a"
    assert attrs.resolution_location == :agent
    assert attrs.allowed_methods == ["GET", "POST"]
    assert attrs.allowed_paths == ["/api/v1/"]
    assert attrs.allowed_hosts == ["device.example.com"]
    assert attrs.allowed_ports == [443, 8443]
    assert attrs.issued_by_actor_id == "user-1"

    [grant] = prepared.payload_fields["credential_brokers"]

    assert grant["schema"] == CredentialBrokerGrant.schema()
    assert grant["grant_type"] == "http_api_callout"

    assert grant["credential_secret_ref"] ==
             "credentialref:network-credential-secret:#{@secret_id}"

    assert prepared.context == %{credential_broker_grant_ids: ["grant-device-api-call"]}
    refute inspect(prepared) =~ "Bearer "
  end

  test "prepare_poll scopes poll grants to the action target job" do
    invocation =
      invocation(%{
        descriptor:
          descriptor(%{
            credential_requirements: %{
              "credential_secret_ref" => "credentialref:network-credential-secret:#{@secret_id}",
              "purpose" => "fetch-result"
            }
          })
      })

    target = %ActionInvocationTarget{
      id: "job-1",
      target_snapshot: %{"interface_uid" => "iface-1"}
    }

    assert {:ok, _prepared} =
             CredentialGrants.prepare_poll(invocation, target, assignment(),
               grant_issuer: {FakeGrantIssuer, :issue},
               test_pid: self()
             )

    assert_receive {:grant_attrs, attrs}
    assert attrs.secret_ref == "credentialref:network-credential-secret:#{@secret_id}"
    assert attrs.target_kind == "interface"
    assert attrs.target_id == "iface-1"
    assert attrs.metadata["phase"] == "poll"
  end

  test "required descriptor credential without selected secret fails closed" do
    invocation =
      invocation(%{
        descriptor:
          descriptor(%{
            credential_requirements: %{
              "credentials" => [
                %{
                  "name" => "api",
                  "credential_secret_input" => "api_secret_id",
                  "required" => true
                }
              ]
            }
          }),
        input_values: %{}
      })

    assert {:error, {:missing_credential_for_requirement, "api"}} =
             CredentialGrants.prepare_launch(invocation, assignment(),
               grant_issuer: {FakeGrantIssuer, :issue},
               test_pid: self()
             )

    refute_receive {:grant_attrs, _}
  end

  defp invocation(overrides) do
    base = %ActionInvocation{
      id: "invocation-1",
      provider_id: "provider-1",
      descriptor_id: "descriptor-1",
      action_id: "http.restart",
      action_version: "1.0.0",
      descriptor_hash: "sha256:test",
      requested_by_actor_id: "user-1",
      provider: provider(),
      descriptor: descriptor(),
      target_snapshots: [%{"device_uid" => "device-1"}],
      input_values: %{},
      redacted_input_values: %{},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp provider(overrides \\ %{}) do
    base = %ActionProvider{
      id: "provider-1",
      provider_type: :wasm_plugin,
      plugin_package_id: "package-1",
      credential_requirements: %{},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp descriptor(overrides \\ %{}) do
    base = %ActionDescriptor{
      id: "descriptor-1",
      provider_id: "provider-1",
      action_id: "http.restart",
      version: "1.0.0",
      timeout_seconds: 120,
      credential_requirements: %{},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp assignment do
    %PluginAssignment{
      id: "assignment-1",
      plugin_package_id: "package-1",
      agent_uid: "agent-a",
      timeout_seconds: 45
    }
  end
end
