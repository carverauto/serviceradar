defmodule ServiceRadarAgentGateway.ApplicationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.PublisherPool
  alias ServiceRadar.Edge.PublisherSupervisor

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
      previous = Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher)

      Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher, enabled: true)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher)
          value -> Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher, value)
        end
      end)

      :ok
    end

    test "ensures the edge publisher lanes are supervised when publishing is enabled" do
      # "in the child list OR already running" is the real invariant, and it is what makes this
      # work in both environments. Every core child carries an "already started" guard so core and
      # the gateway can share a VM, which means PRESENCE alone is environment-dependent: locally
      # the application is running and the entry is correctly skipped; under Bazel it is not
      # running and the entry must be present.
      #
      # Deleting the entry fails BOTH ways -- nothing composes it and nothing started it -- which
      # is the mutation this exists to catch.
      composed? = PublisherSupervisor in ServiceRadarAgentGateway.Application.core_children()
      running? = is_pid(Process.whereis(PublisherSupervisor))

      assert composed? or running?,
             "the gateway neither composes nor runs the edge publisher lanes; publishes fail closed"
    end

    test "omits them entirely when no publisher is enabled" do
      # NOT VACUOUS: the entry is conditional, so a test that only ever saw it present could not
      # tell a real gate from an unconditional one. Disabling every publisher must remove it.
      for key <- [
            :sysmon_metrics_publisher,
            :snmp_metrics_publisher,
            :icmp_metrics_publisher,
            :plugin_metrics_publisher,
            :rperf_metrics_publisher,
            :mtr_metrics_publisher,
            :sweep_metrics_publisher,
            :otlp_relay_publisher
          ] do
        Application.put_env(:serviceradar_agent_gateway, key, enabled: false)
      end

      refute PublisherSupervisor in ServiceRadarAgentGateway.Application.core_children()
    end
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
