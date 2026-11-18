defmodule ServiceRadarWebNGWeb.WebPropertyLiveUnitTest do
  @moduledoc """
  DB-free unit tests for `WebPropertyLive.Index` and `WebPropertyLive.Show`
  verifying zero DB/SRQL queries on disconnected mount and render safety.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
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
