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

  describe "edge-site leaf bundle templates" do
    @site %{name: "NYC Office", slug: "nyc-office", nats_leaf_url: "tls://10.0.1.50:4222"}
    @leaf %{upstream_url: "tls://acme.nats.serviceradar.cloud:7422", local_listen: "0.0.0.0:4222"}

    test "the leaf remote dials the leaf server's upstream URL" do
      config = NatsLeafConfigGenerator.generate_config(@site, @leaf)

      assert config =~ ~s(url: "tls://acme.nats.serviceradar.cloud:7422")
      assert config =~ ~s(cert_file: "/etc/nats/certs/nats-leaf.pem")
    end

    test "references account creds only when the bundle ships them" do
      refute NatsLeafConfigGenerator.generate_config(@site, @leaf) =~ "credentials:"

      assert NatsLeafConfigGenerator.generate_config(@site, @leaf, with_credentials: true) =~
               ~s(credentials: "/etc/nats/creds/account.creds")
    end

    test "setup script manages the serviceradar-nats unit with packaged ownership" do
      script = NatsLeafConfigGenerator.generate_setup_script(@site)

      assert script =~ "UNIT=serviceradar-nats"
      assert script =~ ~s(systemctl restart "$UNIT")
      refute script =~ "nats-server.service"
      refute script =~ "systemctl enable nats-server"
      assert script =~ "-o nats -g serviceradar"
      refute script =~ "nats:nats"
      assert script =~ "nats-server -c nats/nats-leaf.conf -t"
      refute script =~ "account.creds"

      assert NatsLeafConfigGenerator.generate_setup_script(@site, with_credentials: true) =~
               "creds/account.creds /etc/nats/creds/account.creds"
    end

    test "setup script is valid bash" do
      path = Path.join(System.tmp_dir!(), "leaf-setup-#{System.unique_integer([:positive])}.sh")

      File.write!(
        path,
        NatsLeafConfigGenerator.generate_setup_script(@site, with_credentials: true)
      )

      on_exit(fn -> File.rm(path) end)

      assert {_, 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
    end
  end
end
