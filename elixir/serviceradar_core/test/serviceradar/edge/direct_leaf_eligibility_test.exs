defmodule ServiceRadar.Edge.DirectLeafEligibilityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.DirectLeafEligibility

  @site %{status: :active, nats_leaf_url: "tls://nats.edge.internal:4222"}
  @leaf %{status: :connected}

  defp direct_params(overrides \\ %{}) do
    Map.merge(
      %{
        "output" => %{"backend" => "jetstream"},
        "nats" => %{
          "url" => "tls://nats.edge.internal:4222",
          "tls" => %{
            "cert_file" => "/etc/serviceradar/edge/nats-client.pem",
            "key_file" => "/etc/serviceradar/edge/nats-client-key.pem",
            "ca_file" => "/etc/serviceradar/edge/nats-ca.pem"
          }
        }
      },
      overrides
    )
  end

  test "accepts direct JetStream only for an active connected registered leaf" do
    assert {:ok, params} =
             DirectLeafEligibility.validate(direct_params(), @site, @leaf)

    assert params["output"]["backend"] == "jetstream"
  end

  test "ordinary agent relay does not require a leaf" do
    assert {:ok, params} = DirectLeafEligibility.validate(%{}, nil, nil)
    assert params == %{}
  end

  test "rejects direct mode without an assignment site" do
    assert {:error, :edge_site_not_selected} =
             DirectLeafEligibility.validate(direct_params(), nil, nil)
  end

  test "rejects a mismatched or central endpoint" do
    params = put_in(direct_params(), ["nats", "url"], "tls://nats.central.internal:4222")

    assert {:error, :leaf_endpoint_mismatch} =
             DirectLeafEligibility.validate(params, @site, @leaf)
  end

  test "rejects an unready leaf" do
    assert {:error, :edge_site_not_active} =
             DirectLeafEligibility.validate(direct_params(), %{@site | status: :pending}, @leaf)

    assert {:error, :leaf_server_not_connected} =
             DirectLeafEligibility.validate(direct_params(), @site, %{status: :provisioned})
  end

  test "requires mTLS and does not accept creds delivery" do
    no_tls = put_in(direct_params(), ["nats", "tls"], nil)
    creds = put_in(direct_params(), ["nats", "creds_file"], "/var/lib/otel/nats.creds")

    assert {:error, :leaf_mtls_required} =
             DirectLeafEligibility.validate(no_tls, @site, @leaf)

    assert {:error, :creds_delivery_not_supported} =
             DirectLeafEligibility.validate(creds, @site, @leaf)
  end

  test "rejects an unbounded subject contract" do
    params = put_in(direct_params(), ["nats", "subject"], "events.>")

    assert {:error, :invalid_subject_scope} =
             DirectLeafEligibility.validate(params, @site, @leaf)
  end
end
