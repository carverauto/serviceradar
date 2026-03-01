defmodule ServiceRadarWebNGWeb.SRQLQueryInputPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ServiceRadarWebNG.Generators.SRQLGenerators
  alias ServiceRadarWebNG.TestSupport.PropertyOpts
  alias ServiceRadarWebNG.TestSupport.SRQLStub
  alias ServiceRadarWebNGWeb.DashboardLive.Index, as: DashboardLive
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  setup do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, SRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    :ok
  end

  property "SRQL.Page.load_list/5 never crashes for malformed query params" do
    check all(
            q <- SRQLGenerators.untrusted_param_value(),
            limit <- SRQLGenerators.untrusted_param_value(),
            extra <- SRQLGenerators.json_map(max_length: 4),
            uri <- StreamData.string(:printable, max_length: 160),
            max_runs: PropertyOpts.max_runs()
          ) do
      socket =
        %Phoenix.LiveView.Socket{}
        |> SRQLPage.init("devices", builder_available: true)

      params = Map.merge(extra, %{"q" => q, "limit" => limit})

      _socket =
        SRQLPage.load_list(socket, params, uri, :results, default_limit: 100, max_limit: 500)
    end
  end

  property "DashboardLive.handle_params/3 never crashes for malformed query params" do
    check all(
            q <- SRQLGenerators.untrusted_param_value(),
            limit <- SRQLGenerators.untrusted_param_value(),
            extra <- SRQLGenerators.json_map(max_length: 4),
            uri <- StreamData.string(:printable, max_length: 160),
            max_runs: PropertyOpts.max_runs()
          ) do
      {:ok, socket} = DashboardLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      params = Map.merge(extra, %{"q" => q, "limit" => limit})
      assert {:noreply, _socket} = DashboardLive.handle_params(params, uri, socket)
    end
  end

  property "DashboardLive handle_event callbacks never crash for malformed params" do
    check all(
            q <- SRQLGenerators.untrusted_param_value(),
            builder <- SRQLGenerators.untrusted_param_value(),
            idx <- SRQLGenerators.untrusted_param_value(),
            max_runs: PropertyOpts.max_runs()
          ) do
      {:ok, socket} = DashboardLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      assert {:noreply, socket} = DashboardLive.handle_event("srql_change", %{"q" => q}, socket)

      assert {:noreply, socket} =
               DashboardLive.handle_event("srql_builder_toggle", %{"q" => q}, socket)

      assert {:noreply, socket} =
               DashboardLive.handle_event("srql_builder_change", %{"builder" => builder}, socket)

      assert {:noreply, socket} =
               DashboardLive.handle_event(
                 "srql_builder_add_filter",
                 %{"builder" => builder},
                 socket
               )

      assert {:noreply, socket} =
               DashboardLive.handle_event("srql_builder_remove_filter", %{"idx" => idx}, socket)

      assert {:noreply, _socket} =
               DashboardLive.handle_event("srql_builder_apply", %{"builder" => builder}, socket)
    end
  end
end
