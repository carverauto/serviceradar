defmodule ServiceRadarWebNGWeb.WebPropertyLiveUnitTest do
  @moduledoc """
  DB-free unit tests for `WebPropertyLive.Index` and `WebPropertyLive.Show`
  verifying zero DB/SRQL queries on disconnected mount and render safety.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.WebPropertyLive.Index
  alias ServiceRadarWebNGWeb.WebPropertyLive.Show

  @moduletag :db_free

  defmodule SpySRQL do
    @moduledoc false
    def query(query, opts) do
      if pid = Process.get(:web_property_spy_pid) do
        send(pid, {:srql_called, query, opts})
      end

      {:ok, %{"results" => [], "pagination" => %{}}}
    end
  end

  test "WebPropertyLive.Index performs zero SRQL queries on disconnected mount and handle_params" do
    prev = Application.get_env(:serviceradar_web_ng, :srql_module)
    Process.put(:web_property_spy_pid, self())

    try do
      Application.put_env(:serviceradar_web_ng, :srql_module, SpySRQL)

      socket = disconnected_socket(["devices.view", "settings.networks.manage"])
      {:ok, socket} = Index.mount(%{}, %{}, socket)
      {:noreply, socket} = Index.handle_params(%{}, "https://example.test/websites", socket)

      refute_received {:srql_called, _, _}
      assert socket.assigns.srql.loading
      assert socket.assigns.srql.query == "in:websites sort:name:asc limit:50"

      html = render_component(&Index.render/1, socket.assigns)
      assert html =~ "Websites"
      assert html =~ "new-website-button"
      assert html =~ "open-web-rum-dashboard-button"
      assert html =~ "/dashboards/web-rum"
    after
      if prev do
        Application.put_env(:serviceradar_web_ng, :srql_module, prev)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end
  end

  test "WebPropertyLive.Show performs zero SRQL queries on disconnected mount and handle_params" do
    prev = Application.get_env(:serviceradar_web_ng, :srql_module)
    Process.put(:web_property_spy_pid, self())

    try do
      Application.put_env(:serviceradar_web_ng, :srql_module, SpySRQL)

      id = Ash.UUID.generate()
      socket = disconnected_socket(["devices.view"])
      {:ok, socket} = Show.mount(%{}, %{}, socket)

      {:noreply, socket} =
        Show.handle_params(%{"id" => id}, "https://example.test/websites/#{id}", socket)

      refute_received {:srql_called, _, _}
      assert socket.assigns.web_property_id == id
      assert is_nil(socket.assigns.web_property)
    after
      if prev do
        Application.put_env(:serviceradar_web_ng, :srql_module, prev)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end
  end

  test "WebPropertyLive.Index and Show deny access without devices.view" do
    socket = disconnected_socket(["observability.logs.view"])
    {:ok, socket} = Index.mount(%{}, %{}, socket)
    {:noreply, denied_index} = Index.handle_params(%{}, "https://example.test/websites", socket)

    assert {:live, :redirect, %{to: "/dashboard"}} = denied_index.redirected

    show_socket = disconnected_socket(["observability.logs.view"])
    {:ok, show_socket} = Show.mount(%{}, %{}, show_socket)
    id = Ash.UUID.generate()

    {:noreply, denied_show} =
      Show.handle_params(%{"id" => id}, "https://example.test/websites/#{id}", show_socket)

    assert {:live, :redirect, %{to: "/dashboard"}} = denied_show.redirected
  end

  test "invalid rum_sample_rate text is rejected instead of silently resetting to 1.0" do
    socket = manager_socket()
    {:ok, index_socket} = Index.mount(%{}, %{}, socket)

    for bad_rate <- ["abc", "0.5ms"] do
      {:noreply, failed_index} =
        Index.handle_event(
          "create_web_property",
          %{
            "web_property" => %{
              "name" => "Shop",
              "canonical_origin" => "https://shop.example.com",
              "rum_sample_rate" => bad_rate
            }
          },
          index_socket
        )

      assert is_binary(failed_index.assigns.form_error)
      assert failed_index.assigns.form_error =~ "rum_sample_rate"
      assert failed_index.assigns.create_form.params["rum_sample_rate"] == bad_rate
    end

    wp = %WebProperty{
      id: Ash.UUID.generate(),
      name: "Shop",
      canonical_origin: "https://shop.example.com",
      environment: :production,
      rum_enabled: true,
      rum_sample_rate: 0.5,
      anonymize_client_ip: true,
      allowed_origins: [],
      allowed_query_keys: [],
      trace_propagate_origins: []
    }

    {:ok, show_socket} = Show.mount(%{}, %{}, manager_socket())

    show_socket =
      show_socket
      |> Show.apply_property_state(wp, [], [], [])
      |> Map.update!(:assigns, &Map.put(&1, :editing?, true))

    for bad_rate <- ["abc", "0.5ms"] do
      {:noreply, failed_show} =
        Show.handle_event(
          "save_web_property",
          %{
            "web_property" => %{
              "name" => "Shop",
              "canonical_origin" => "https://shop.example.com",
              "rum_sample_rate" => bad_rate
            }
          },
          show_socket
        )

      assert is_binary(failed_show.assigns.form_error)
      assert failed_show.assigns.form_error =~ "rum_sample_rate"
      assert failed_show.assigns.edit_form.params["rum_sample_rate"] == bad_rate
    end
  end

  test "Show.apply_property_state preserves active @edit_form when editing? is true" do
    wp_initial = %WebProperty{
      id: Ash.UUID.generate(),
      name: "Initial Site",
      canonical_origin: "https://shop.example.com",
      environment: :production,
      rum_enabled: true,
      rum_sample_rate: 0.5,
      anonymize_client_ip: true,
      allowed_origins: [],
      allowed_query_keys: [],
      trace_propagate_origins: [],
      edge_provider: nil
    }

    wp_posture_updated = %{wp_initial | edge_provider: "cloudflare", name: "Posture Updated"}

    {:ok, socket} = Show.mount(%{}, %{}, manager_socket())
    socket = Show.apply_property_state(socket, wp_initial, [], [], [])

    unsaved_form =
      Phoenix.Component.to_form(
        %{
          "name" => "Unsaved Operator Edit",
          "canonical_origin" => "https://shop.example.com",
          "environment" => "staging",
          "rum_sample_rate" => "0.25"
        },
        as: :web_property
      )

    editing_socket =
      Map.update!(socket, :assigns, fn assigns ->
        assigns
        |> Map.put(:editing?, true)
        |> Map.put(:edit_form, unsaved_form)
      end)

    refreshed_while_editing =
      Show.apply_property_state(editing_socket, wp_posture_updated, [], [], [])

    assert refreshed_while_editing.assigns.web_property.edge_provider == "cloudflare"
    assert refreshed_while_editing.assigns.edit_form.params["name"] == "Unsaved Operator Edit"
    assert refreshed_while_editing.assigns.edit_form.params["environment"] == "staging"

    non_editing_socket =
      Map.update!(editing_socket, :assigns, &Map.put(&1, :editing?, false))

    refreshed_when_not_editing =
      Show.apply_property_state(non_editing_socket, wp_posture_updated, [], [], [])

    assert refreshed_when_not_editing.assigns.edit_form.params["name"] == "Posture Updated"
  end

  test "WebPropertyLive.Show renders a Boomerang snippet with absolute script and public beacon URLs" do
    wp = rum_web_property()

    with_otlp_onboarding([http_endpoint: "https://otlp.example.com/"], fn ->
      {:ok, show_socket} = Show.mount(%{}, %{}, manager_socket())
      show_socket = Show.apply_property_state(show_socket, wp, [], [], [])

      html = render_component(&Show.render/1, show_socket.assigns)
      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, "#open-web-rum-dashboard-button"))
      assert html =~ "/dashboards/web-rum"
      refute Enum.empty?(LazyHTML.query(doc, "#copy-rum-snippet-button"))
      assert Enum.empty?(LazyHTML.query(doc, "#rum-snippet-unconfigured"))

      boomerang_text = doc |> LazyHTML.query("#rum-boomerang-snippet") |> LazyHTML.text()
      assert boomerang_text =~ ~s(beaconUrl: "https://otlp.example.com/rum/v1/beacon")
      assert boomerang_text =~ ~s(crossorigin="anonymous")
      assert boomerang_text =~ "sr_rum_unit_test_key"
      assert boomerang_text =~ "0.25"
      assert boomerang_text =~ "tracePropagateOrigins"
      assert boomerang_text =~ "https://api.example.com"

      [_, script_src] = Regex.run(~r/<script src="([^"]+)"/, boomerang_text)
      script_uri = URI.parse(script_src)
      assert script_uri.scheme in ["http", "https"]
      assert is_binary(script_uri.host) and script_uri.host != ""
      assert script_uri.path == "/assets/rum/boomerang-sr.min.js"

      {config_idx, _} = :binary.match(boomerang_text, "window.BOOMR_config")
      {script_idx, _} = :binary.match(boomerang_text, "<script src=")
      assert config_idx < script_idx
    end)
  end

  test "WebPropertyLive.Show withholds the RUM snippet when no public ingest endpoint is configured" do
    with_otlp_onboarding([http_endpoint: ""], fn ->
      {:ok, show_socket} = Show.mount(%{}, %{}, manager_socket())
      show_socket = Show.apply_property_state(show_socket, rum_web_property(), [], [], [])

      doc = LazyHTML.from_fragment(render_component(&Show.render/1, show_socket.assigns))

      assert Enum.empty?(LazyHTML.query(doc, "#rum-boomerang-snippet"))
      assert Enum.empty?(LazyHTML.query(doc, "#copy-rum-snippet-button"))
      refute Enum.empty?(LazyHTML.query(doc, "#rum-snippet-unconfigured"))
    end)
  end

  defp rum_web_property do
    %WebProperty{
      id: Ash.UUID.generate(),
      name: "Portal",
      canonical_origin: "https://portal.example.com",
      environment: :production,
      rum_site_key: "sr_rum_unit_test_key",
      rum_enabled: true,
      rum_sample_rate: 0.25,
      anonymize_client_ip: true,
      allowed_origins: ["https://portal.example.com"],
      allowed_query_keys: [],
      trace_propagate_origins: ["https://api.example.com"]
    }
  end

  defp with_otlp_onboarding(config, fun) do
    prev = Application.fetch_env(:serviceradar_web_ng, :otlp_onboarding)
    Application.put_env(:serviceradar_web_ng, :otlp_onboarding, config)

    try do
      fun.()
    after
      case prev do
        {:ok, value} -> Application.put_env(:serviceradar_web_ng, :otlp_onboarding, value)
        :error -> Application.delete_env(:serviceradar_web_ng, :otlp_onboarding)
      end
    end
  end

  defp manager_socket do
    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: ServiceRadarWebNGWeb.Router,
      private: %{live_temp: %{}, lifecycle: %Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :index,
        current_scope: %Scope{
          user: %{id: "op-1", role: :operator},
          permissions: MapSet.new(["devices.view", "settings.networks.manage"])
        }
      }
    }
  end

  defp disconnected_socket(permissions) do
    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: ServiceRadarWebNGWeb.Router,
      private: %{live_temp: %{}, lifecycle: %Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :index,
        current_scope: %Scope{user: nil, permissions: MapSet.new(permissions)}
      }
    }
  end
end
