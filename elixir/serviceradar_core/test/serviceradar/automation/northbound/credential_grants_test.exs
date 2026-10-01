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
  @credential_manager %{
    id: "credential-manager",
    role: :viewer,
    permissions: MapSet.new(["settings.credentials.manage"])
  }

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

  defmodule FakePackageContext do
    @moduledoc false

    @bound_ref "credentialref:network-credential-secret:018f3f56-2222-7222-8333-123456789abc"

    def bound_ref, do: @bound_ref

    def schedule_credential(%{id: "assignment-1"}, "example_account", _opts),
      do: {:ok, %{secret_ref: @bound_ref, credential_rule_id: "rule-bound"}}

    def schedule_credential(_assignment, _ref_name, _opts), do: {:error, :no_bound_schedule}
  end

  describe "declared credential sources" do
    test "assignment_schedule takes the bound schedule ref and ignores secret inputs" do
      invocation =
        invocation(%{
          descriptor:
            descriptor(%{
              credential_requirements: %{
                "source_account" => %{
                  "credential_source" => "assignment_schedule",
                  "requirement" => "example_account",
                  "credential_secret_input" => "api_secret_id",
                  "purpose" => "management",
                  "allow" => %{"methods" => ["POST"], "hosts" => ["api.example.com"]},
                  "ttl_seconds" => 90
                }
              }
            }),
          input_values: %{"api_secret_id" => @secret_id}
        })

      assert {:ok, _prepared} =
               CredentialGrants.prepare_launch(invocation, assignment(),
                 grant_issuer: {FakeGrantIssuer, :issue},
                 plugin_package_context: FakePackageContext,
                 test_pid: self()
               )

      assert_receive {:grant_attrs, attrs}
      assert attrs.secret_ref == FakePackageContext.bound_ref()
      assert attrs.secret_id == nil
      assert attrs.credential_rule_id == "rule-bound"
      assert attrs.allowed_methods == ["POST"]
      assert attrs.allowed_hosts == ["api.example.com"]
      assert attrs.ttl_seconds == 90
      assert attrs.metadata["requirement_name"] == "source_account"
      assert attrs.metadata["credential_source"] == "assignment_schedule"
    end

    test "assignment_schedule with no bound schedule fails closed" do
      invocation =
        invocation(%{
          descriptor:
            descriptor(%{
              credential_requirements: %{
                "source_account" => %{
                  "credential_source" => "assignment_schedule",
                  "requirement" => "other_account"
                }
              }
            })
        })

      assert {:error, {:no_bound_schedule_credential, "source_account", "other_account"}} =
               CredentialGrants.prepare_launch(invocation, assignment(),
                 grant_issuer: {FakeGrantIssuer, :issue},
                 plugin_package_context: FakePackageContext,
                 test_pid: self()
               )

      refute_receive {:grant_attrs, _}
    end

    test "launch-only actors cannot select package credential rules" do
      invocation =
        invocation(%{
          descriptor:
            descriptor(%{
              credential_requirements: %{
                "destination_account" => %{
                  "credential_source" => "package_rule",
                  "rule_input" => "destination_rule_id",
                  "required" => true
                }
              }
            }),
          input_values: %{"destination_rule_id" => "rule-eligible"}
        })

      assert {:error, :credential_rule_permission_required} =
               CredentialGrants.prepare_launch(invocation, assignment(),
                 grant_issuer: {FakeGrantIssuer, :issue},
                 plugin_package_context: FakePackageContext,
                 actor: %{
                   id: "launcher",
                   role: :viewer,
                   permissions: MapSet.new(["northbound.actions.launch"])
                 },
                 test_pid: self()
               )

      refute_receive {:grant_attrs, _}
    end

    test "declared sources require the provider's own plugin package" do
      requirement = %{
        "credential_source" => "assignment_schedule",
        "requirement" => "example_account"
      }

      for provider <- [
            provider(%{provider_type: :native, plugin_package_id: nil}),
            provider(%{plugin_package_id: "package-2"})
          ] do
        invocation =
          invocation(%{
            provider: provider,
            descriptor: descriptor(%{credential_requirements: requirement})
          })

        assert {:error, {:credential_source_requires_plugin_package, nil, "assignment_schedule"}} =
                 CredentialGrants.prepare_launch(invocation, assignment(),
                   grant_issuer: {FakeGrantIssuer, :issue},
                   plugin_package_context: FakePackageContext,
                   test_pid: self()
                 )
      end
    end

    test "an unknown credential source fails closed" do
      invocation =
        invocation(%{
          descriptor:
            descriptor(%{
              credential_requirements: %{
                "api" => %{"credential_source" => "operator_input", "secret_id" => @secret_id}
              }
            })
        })

      assert {:error, {:unsupported_credential_source, "api", "operator_input"}} =
               CredentialGrants.prepare_launch(invocation, assignment(),
                 grant_issuer: {FakeGrantIssuer, :issue},
                 plugin_package_context: FakePackageContext,
                 test_pid: self()
               )

      refute_receive {:grant_attrs, _}
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
      target_snapshots: [
        %{"kind" => "device", "device_uid" => "device-1", "agent_id" => "agent-a"}
      ],
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
