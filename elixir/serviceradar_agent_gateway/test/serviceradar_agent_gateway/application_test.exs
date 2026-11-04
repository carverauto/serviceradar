defmodule ServiceRadarAgentGateway.ApplicationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherSupervisor
  alias ServiceRadar.NATS.Connection

  @publisher_keys [
    :sysmon_metrics_publisher,
    :snmp_metrics_publisher,
    :icmp_metrics_publisher,
    :plugin_metrics_publisher,
    :rperf_metrics_publisher,
    :mtr_metrics_publisher,
    :sweep_metrics_publisher,
    :otlp_relay_publisher
  ]

  test "fails closed when edge listener certs are missing" do
    cert_dir = unique_tmp_dir!("gateway-app-test")

    previous = Application.get_env(:serviceradar_agent_gateway, :gateway_cert_dir)
    Application.put_env(:serviceradar_agent_gateway, :gateway_cert_dir, cert_dir)

    on_exit(fn ->
      restore_env(:gateway_cert_dir, previous)
      File.rm_rf(cert_dir)
    end)

    assert_raise RuntimeError, ~r/No mTLS certs available/, fn ->
      ServiceRadarAgentGateway.Application.edge_server_ssl_opts!()
    end
  end

  describe "root composition" do
    # Deleting edge_publisher_pools_child() from the child list left all 32 core and 37 gateway
    # tests green; only an unused-helper warning exposed it. This binds the LIST.
    #
    # Asserted on the composed list rather than the running tree on purpose: under Bazel the
    # gateway application is not started, so a which_children/1 assertion passed locally and
    # failed there -- proving where it ran, not what it composed.
    setup do
      previous = Map.new(@publisher_keys, &{&1, Application.get_env(:serviceradar_agent_gateway, &1)})
      on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
      :ok
    end

    # The edge-record pipeline has no switch (enable-edge-record-pipeline-by-default, Decision 1),
    # so the lanes and their NATS connection are composed whatever the other publishers are set to.
    test "always composes the edge publisher lanes and the NATS connection, even with every other publisher off" do
      for key <- @publisher_keys do
        Application.put_env(:serviceradar_agent_gateway, key, enabled: false)
      end

      children = ServiceRadarAgentGateway.Application.core_children()

      assert edge_publisher_lanes_composed?(children),
             "the gateway does not compose the edge publisher lanes; publishes fail closed"

      assert ServiceRadar.NATS.Supervisor in children or Process.whereis(Connection.connection_name()),
             "the gateway composes no NATS connection for the edge publisher lanes"
    end
  end

  # Composed WITH a publisher. A bare PublisherSupervisor starts every lane's accountant and
  # transport but no PublishPipeline, which leaves the edge record ingest server nothing to offer to.
  defp edge_publisher_lanes_composed?(children) do
    Enum.any?(children, fn
      {PublisherSupervisor, [publisher: publisher]} -> is_function(publisher, 2)
      _child -> false
    end)
  end

  defp unique_tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(dir)
    dir
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
