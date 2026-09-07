defmodule ServiceRadarWebNGWeb.Components.RemoteTerminalComponentsTest do
  @moduledoc false

  # Regression test for https://github.com/carverauto/serviceradar/issues/4373:
  # the Proxmox console LiveView crashed on mount because
  # `remote_console_terminal` rendered a server-side `react_component/1` with
  # `static: false`, which calls `Phoenix.ReactServer` -- a process that is
  # deliberately not supervised (see `ServiceRadarWebNG.Application`). The
  # terminal components must stay client-only, matching the SSH console's
  # hook + `data-props` pattern. Rendering here would exit with `:noproc`
  # before that fix.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.ReactComponents

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    case start_supervised(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "remote_console_terminal renders the client-only hook without SSR" do
    html =
      render_component(&ReactComponents.remote_console_terminal/1, %{
        id: "remote-console-terminal-session-1",
        session_id: "session-1",
        ticket: "srpve-test-ticket",
        websocket_path: "/v1/proxmox/console-sessions/session-1/stream",
        title: "PVE host console",
        subtitle: "termproxy via agent-1"
      })

    assert html =~ ~s(phx-hook="RemoteConsoleTerminal")
    assert html =~ ~s(phx-update="ignore")
    # The client hook authenticates the websocket stream with these props; the
    # ticket must reach the browser (it was previously withheld from the SSR
    # markup only, which no longer exists).
    assert html =~ "session-1"
    assert html =~ "srpve-test-ticket"
    assert html =~ "/v1/proxmox/console-sessions/session-1/stream"
    assert html =~ "Loading remote console..."
  end
end
