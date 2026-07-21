defmodule ServiceRadar.Edge.DirectLeafIdentityIssuerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.DirectLeafIdentityIssuer
  alias ServiceRadar.Edge.DirectLeafScope

  @assignment_id "f8828fb5-1df4-4058-adc8-e82e0825257b"

  test "issues only through the authenticated agent gateway and scopes the add-on identity" do
    parent = self()
    params = direct_params()
    {:ok, scope} = DirectLeafScope.build(params)

    rpc_call = fn gateway_node, module, function, args, timeout ->
      send(parent, {:rpc, gateway_node, module, function, args, timeout})

      {:ok,
       %{
         certificate_pem: "cert-pem",
         private_key_pem: "key-pem",
         ca_chain_pem: "ca-pem",
         certificate_fingerprint: String.duplicate("a", 64)
       }}
    end

    assert {:ok, identity} =
             DirectLeafIdentityIssuer.issue(
               %{
                 id: @assignment_id,
                 agent_uid: "agent-1",
                 edge_site_id: "site-1",
                 params: params,
                 direct_subject_scope: scope
               },
               edge_site_fetcher: fn "site-1" ->
                 {:ok,
                  %{
                    status: :active,
                    nats_leaf_url: "tls://leaf.example:4222",
                    nats_leaf_server: %{status: :connected}
                  }}
               end,
               session_resolver: fn "agent-1" ->
                 {:ok,
                  %{
                    agent_id: "agent-1",
                    partition_id: "partition-a",
                    control_session_pid: self()
                  }}
               end,
               rpc_call: rpc_call
             )

    assert identity.component_id == "addon-" <> String.replace(@assignment_id, "-", "")
    assert identity.partition_id == "partition-a"
    assert identity.scope == scope
    assert identity.authorization_status == :pending

    assert_receive {:rpc, _node, ServiceRadarAgentGateway.CertIssuer, :issue_agent_bundle,
                    [component_id, "partition-a", :addon, issuer_opts], 10_000}

    assert component_id == identity.component_id
    assert issuer_opts[:authorized_component_id] == component_id
    assert issuer_opts[:authorized_partition_id] == "partition-a"
    refute Keyword.has_key?(issuer_opts, :account_seed)
    refute Keyword.has_key?(issuer_opts, :creds_file)
  end

  test "rejects a stale scope before contacting the gateway" do
    params = direct_params()

    assert {:error, :direct_subject_scope_stale} =
             DirectLeafIdentityIssuer.issue(
               %{
                 id: @assignment_id,
                 agent_uid: "agent-1",
                 edge_site_id: "site-1",
                 params: params,
                 direct_subject_scope: %{}
               },
               edge_site_fetcher: fn _ -> flunk("must not load the leaf") end,
               session_resolver: fn _ -> flunk("must not resolve the session") end
             )
  end

  defp direct_params do
    %{
      "output" => %{"backend" => "jetstream"},
      "nats" => %{
        "url" => "tls://leaf.example:4222",
        "subject" => "events.otlp",
        "stream" => "events",
        "tls" => %{
          "cert_file" => "/run/serviceradar/otel/cert.pem",
          "key_file" => "/run/serviceradar/otel/key.pem",
          "ca_file" => "/run/serviceradar/otel/ca.pem"
        }
      }
    }
  end
end
