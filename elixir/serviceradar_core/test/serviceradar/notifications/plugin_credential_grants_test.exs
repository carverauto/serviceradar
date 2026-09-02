defmodule ServiceRadar.Notifications.PluginCredentialGrantsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.PluginCredentialGrants
  alias ServiceRadar.Plugins.SecretRefs

  @secret_id "11111111-1111-1111-1111-111111111111"

  defp channel(overrides \\ %{}) do
    Map.merge(
      %{
        id: "22222222-2222-2222-2222-222222222222",
        config: %{"base_url" => "https://chat.example.test"},
        secret_refs: %{
          "api_token_secret_ref" => SecretRefs.network_credential_ref(@secret_id),
          "_secret_material" => %{"never" => "plaintext"}
        }
      },
      overrides
    )
  end

  defp target(overrides \\ %{}) do
    Map.merge(
      %{
        agent_uid: "site-agent",
        plugin_assignment_id: "33333333-3333-3333-3333-333333333333",
        effective_permissions: %{
          allowed_domains: ["chat.example.test"],
          allowed_networks: [],
          allowed_ports: [443]
        },
        credential_requirements: %{
          "api_token" => %{
            "injection_mode" => "bearer_token",
            "required" => true
          }
        }
      },
      overrides
    )
  end

  test "keeps the sentinel guest-visible and the scoped grant host-only" do
    test_pid = self()

    issuer = fn attrs, _opts ->
      send(test_pid, {:grant_attrs, attrs})

      {:ok,
       %{
         "grant_id" => "44444444-4444-4444-4444-444444444444",
         "credential_secret_ref" => attrs.secret_ref,
         "inject" => attrs.inject,
         "allow" => %{"hosts" => attrs.allowed_hosts}
       }}
    end

    assert {:ok, prepared} =
             PluginCredentialGrants.prepare(channel(), target(),
               delivery_id: "delivery-1",
               grant_issuer: issuer
             )

    assert prepared.channel_config["api_token_secret_ref"] ==
             SecretRefs.network_credential_ref(@secret_id)

    refute Map.has_key?(prepared.channel_config, "_secret_material")
    assert [%{"grant_id" => grant_id}] = prepared.payload_fields["credential_brokers"]
    assert prepared.context.credential_broker_grant_ids == [grant_id]

    assert_received {:grant_attrs, attrs}
    assert attrs.secret_id == @secret_id
    assert attrs.agent_id == "site-agent"
    assert attrs.consumer_kind == :plugin

    assert attrs.inject == %{
             "type" => "bearer_token",
             "name" => "Authorization",
             "scheme" => "Bearer"
           }

    assert attrs.allowed_hosts == ["chat.example.test"]
    assert attrs.allowed_schemes == ["https"]
    assert attrs.allowed_ports == [443]
    assert attrs.metadata["notification_delivery_id"] == "delivery-1"
  end

  test "a required credential must be selected" do
    assert {:error, {:missing_notification_credential, "api_token"}} =
             PluginCredentialGrants.prepare(
               channel(%{secret_refs: %{}}),
               target(),
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "an inline encrypted secret cannot be resolved by an agent grant" do
    assert {:error, {:unsupported_notification_secret_ref, "api_token"}} =
             PluginCredentialGrants.prepare(
               channel(%{secret_refs: %{"api_token_secret_ref" => "secretref:inline"}}),
               target(),
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "a credential grant fails closed without an egress host scope" do
    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             PluginCredentialGrants.prepare(
               channel(%{config: %{}}),
               target(%{
                 effective_permissions: %{
                   allowed_domains: [],
                   allowed_networks: [],
                   allowed_ports: [443]
                 }
               }),
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "a routing-key-only notifier inherits its exact effective assignment scope" do
    test_pid = self()

    channel =
      channel(%{
        config: %{},
        secret_refs: %{
          "routing_key_secret_ref" => SecretRefs.network_credential_ref(@secret_id)
        }
      })

    target =
      target(%{
        effective_permissions: %{
          allowed_domains: ["events.pagerduty.com"],
          allowed_networks: [],
          allowed_ports: [443]
        },
        credential_requirements: %{
          "routing_key" => %{"injection_mode" => "bearer_token", "required" => true}
        }
      })

    assert {:ok, _prepared} =
             PluginCredentialGrants.prepare(channel, target,
               grant_issuer: fn attrs ->
                 send(test_pid, {:grant_attrs, attrs})
                 {:ok, %{"grant_id" => "grant-1"}}
               end
             )

    assert_received {:grant_attrs, attrs}
    assert attrs.allowed_hosts == ["events.pagerduty.com"]
    assert attrs.allowed_schemes == ["https"]
    assert attrs.allowed_ports == [443]
  end

  test "a channel endpoint cannot widen the effective assignment scope" do
    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             PluginCredentialGrants.prepare(
               channel(%{config: %{"base_url" => "https://attacker.example.test"}}),
               target(),
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "a requirement-authored allowlist cannot widen assignment permissions" do
    widened =
      target(%{
        credential_requirements: %{
          "api_token" => %{
            "injection_mode" => "bearer_token",
            "required" => true,
            "allow" => %{"hosts" => ["attacker.example.test"]}
          }
        }
      })

    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             PluginCredentialGrants.prepare(channel(), widened,
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "a wildcard assignment is narrowed to a concrete channel endpoint" do
    test_pid = self()

    wildcard =
      target(%{
        effective_permissions: %{
          allowed_domains: ["*.example.test"],
          allowed_networks: [],
          allowed_ports: [443]
        }
      })

    assert {:ok, _prepared} =
             PluginCredentialGrants.prepare(channel(), wildcard,
               grant_issuer: fn attrs ->
                 send(test_pid, {:grant_attrs, attrs})
                 {:ok, %{"grant_id" => "grant-1"}}
               end
             )

    assert_received {:grant_attrs, attrs}
    assert attrs.allowed_hosts == ["chat.example.test"]
  end

  test "a wildcard-only assignment without a concrete endpoint fails closed" do
    wildcard =
      target(%{
        effective_permissions: %{
          allowed_domains: ["*"],
          allowed_networks: [],
          allowed_ports: [443]
        }
      })

    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             PluginCredentialGrants.prepare(channel(%{config: %{}}), wildcard,
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )
  end

  test "an absent optional requirement produces no grant" do
    optional =
      target(%{
        credential_requirements: %{
          "api_token" => %{"injection_mode" => "bearer_token", "required" => false}
        }
      })

    assert {:ok, prepared} =
             PluginCredentialGrants.prepare(
               channel(%{secret_refs: %{}}),
               optional,
               grant_issuer: fn _attrs -> flunk("issuer must not run") end
             )

    assert prepared.payload_fields == %{}
    assert prepared.context.credential_broker_grant_ids == []
  end

  test "all six canonical modes produce only string-valued host inject maps" do
    requirements = %{
      "http_header" => %{
        "injection_mode" => "http_header",
        "name" => "X-API-Key"
      },
      "bearer_token" => %{"injection_mode" => "bearer_token"},
      "basic_auth" => %{"injection_mode" => "basic_auth"},
      "query" => %{"injection_mode" => "query", "name" => "api_key"},
      "form_urlencoded" => %{
        "injection_mode" => "form_urlencoded",
        "method" => "POST",
        "host" => "chat.example.test",
        "port" => 443,
        "path" => "/oauth/token",
        "field_username" => "username"
      },
      "oauth2_password_bearer" => %{
        "injection_mode" => "oauth2_password_bearer",
        "method" => "POST",
        "host" => "chat.example.test",
        "port" => 443,
        "path" => "/incidents",
        "token_method" => "POST",
        "token_host" => "identity.example.test",
        "token_port" => 443,
        "token_path" => "/oauth/token",
        "field_username" => "username",
        "field_password" => "password",
        "fixed_grant_type" => "password"
      },
      # Token endpoint on the SAME host as the upstream call, which is the
      # shape real client-credentials APIs take (ClearPass issues at
      # /api/oauth and serves data from /api/* on one host). It needs one
      # allowed domain, not two.
      "oauth2_client_credentials" => %{
        "injection_mode" => "oauth2_client_credentials",
        "method" => "GET",
        "host" => "chat.example.test",
        "port" => 443,
        "path" => "/api/session",
        "token_method" => "POST",
        "token_host" => "chat.example.test",
        "token_port" => 443,
        "token_path" => "/api/oauth",
        "field_client_id" => "client_id",
        "field_client_secret" => "client_secret",
        "fixed_grant_type" => "client_credentials"
      }
    }

    for {mode, requirement} <- requirements do
      test_pid = self()

      effective_domains =
        if mode == "oauth2_password_bearer",
          do: ["chat.example.test", "identity.example.test"],
          else: ["chat.example.test"]

      scoped_target =
        target(%{
          credential_requirements: %{"api_token" => requirement},
          effective_permissions: %{
            allowed_domains: effective_domains,
            allowed_networks: [],
            allowed_ports: [443]
          }
        })

      assert {:ok, _prepared} =
               PluginCredentialGrants.prepare(channel(), scoped_target,
                 grant_issuer: fn attrs ->
                   send(test_pid, {:grant_attrs, mode, attrs})
                   {:ok, %{"grant_id" => "grant-#{mode}"}}
                 end
               )

      assert_received {:grant_attrs, ^mode, attrs}
      assert attrs.inject["type"] == mode

      assert Enum.all?(attrs.inject, fn {key, value} ->
               is_binary(key) and is_binary(value) and value != ""
             end)
    end
  end

  test "form injection keeps its exact target and field mappings while port narrows the grant" do
    requirement = %{
      "injection_mode" => "form_urlencoded",
      "method" => "POST",
      "host" => "identity.example.test",
      "port" => 8443,
      "path" => "/oauth/token",
      "field_username" => "username",
      "field_password" => "password"
    }

    assert {:ok, attrs} = issued_attrs(requirement, ["identity.example.test"], [443, 8443])

    assert attrs.inject == %{
             "type" => "form_urlencoded",
             "method" => "POST",
             "host" => "identity.example.test",
             "path" => "/oauth/token",
             "field_username" => "username",
             "field_password" => "password"
           }

    assert attrs.allowed_hosts == ["identity.example.test"]
    assert attrs.allowed_ports == [8443]
  end

  test "oauth token and upstream targets are both bounded by effective assignment permissions" do
    requirement = %{
      "injection_mode" => "oauth2_password_bearer",
      "method" => "POST",
      "host" => "api.example.test",
      "port" => 443,
      "path" => "/incidents",
      "token_method" => "POST",
      "token_host" => "identity.example.test",
      "token_port" => 8443,
      "token_path" => "/oauth/token",
      "field_username" => "username",
      "field_password" => "password",
      "fixed_grant_type" => "password"
    }

    assert {:ok, attrs} =
             issued_attrs(
               requirement,
               ["api.example.test", "identity.example.test"],
               [443, 8443]
             )

    assert attrs.inject["token_host"] == "identity.example.test"
    assert attrs.inject["token_port"] == "8443"
    refute Map.has_key?(attrs.inject, "port")
    # The token target is validated against effective permissions and carried in
    # the inject map, but is not unioned into the upstream request grant. Host
    # and port allowlists are independent, so unioning would accidentally allow
    # api.example.test:8443 as a cross-product target.
    assert attrs.allowed_hosts == ["api.example.test"]
    assert attrs.allowed_ports == [443]

    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             prepare_requirement(
               requirement,
               ["api.example.test"],
               [443, 8443],
               fn _attrs -> flunk("issuer must not run for an out-of-scope token host") end
             )

    assert {:error, {:notification_credential_scope_missing, "api_token"}} =
             prepare_requirement(
               requirement,
               ["api.example.test", "identity.example.test"],
               [443],
               fn _attrs -> flunk("issuer must not run for an out-of-scope token port") end
             )
  end

  test "a stored malformed requirement fails before issuing a grant" do
    malformed = %{
      "injection_mode" => "http_header",
      "name" => true,
      "inject" => %{"type" => "query"}
    }

    assert {:error, {:invalid_notification_credential_requirement, "api_token", errors}} =
             prepare_requirement(
               malformed,
               ["chat.example.test"],
               [443],
               fn _attrs -> flunk("issuer must not run for malformed stored metadata") end
             )

    assert Enum.any?(errors, &String.contains?(&1, ".name must be a string"))
    assert Enum.any?(errors, &String.contains?(&1, ".inject is not allowed"))
  end

  defp issued_attrs(requirement, allowed_domains, allowed_ports) do
    test_pid = self()

    result =
      prepare_requirement(requirement, allowed_domains, allowed_ports, fn attrs ->
        send(test_pid, {:issued_attrs, attrs})
        {:ok, %{"grant_id" => "grant-1"}}
      end)

    with {:ok, _prepared} <- result do
      assert_received {:issued_attrs, attrs}
      {:ok, attrs}
    end
  end

  defp prepare_requirement(requirement, allowed_domains, allowed_ports, issuer) do
    scoped_target =
      target(%{
        credential_requirements: %{"api_token" => requirement},
        effective_permissions: %{
          allowed_domains: allowed_domains,
          allowed_networks: [],
          allowed_ports: allowed_ports
        }
      })

    PluginCredentialGrants.prepare(
      channel(%{config: %{}}),
      scoped_target,
      grant_issuer: issuer
    )
  end
end
