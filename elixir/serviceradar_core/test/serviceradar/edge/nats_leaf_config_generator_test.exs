defmodule ServiceRadar.Edge.NatsLeafConfigGeneratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.NatsLeafConfigGenerator

  test "renders exact assignment subject permissions without a broad events grant" do
    config =
      NatsLeafConfigGenerator.render_direct_leaf_authorization([
        %{
          component_id: "addon-f8828fb51df44058adc8e82e0825257b",
          partition_id: "partition-a",
          # The renderer must ignore any accidental material fields; the leaf
          # bundle receives only the certificate identity and subject scope.
          certificate_pem: "-----BEGIN CERTIFICATE-----secret",
          private_key_pem: "-----BEGIN PRIVATE KEY-----secret",
          scope: %{
            "publish" => [
              "events.otlp.traces.>",
              "events.otlp.metrics.>",
              "logs.otel",
              "$JS.API.STREAM.INFO.events"
            ],
            "subscribe" => ["_INBOX.>", "$JS.ACK.events.>"]
          }
        }
      ])

    assert config =~ "CN=addon-f8828fb51df44058adc8e82e0825257b.partition-a.serviceradar"
    assert config =~ "events.otlp.traces.>"
    assert config =~ "$JS.ACK.events.>"
    refute config =~ "BEGIN CERTIFICATE"
    refute config =~ "BEGIN PRIVATE KEY"
    refute config =~ "\"events.>\""
    refute config =~ "account_seed"
  end
end
