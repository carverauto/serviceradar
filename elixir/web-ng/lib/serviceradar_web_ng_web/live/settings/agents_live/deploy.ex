defmodule ServiceRadarWebNGWeb.Settings.AgentsLive.Deploy do
  @moduledoc """
  LiveView for deploying new agents.

  Provides UI for:
  - Generating agent deployment packages
  - Downloading agent installation scripts
  - Viewing deployment instructions
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadarWebNG.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      socket =
        socket
        |> assign(:page_title, "Deploy Agent")
        |> assign(:can_manage_edge, true)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to agent deployment tools")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/agents/deploy">
        <.settings_nav current_path="/settings/agents/deploy" current_scope={@current_scope} />
        <.edge_nav current_path="/settings/agents/deploy" current_scope={@current_scope} />

        <div class="space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-base-content">Deploy Agent</h1>
              <p class="text-sm text-base-content/60">
                Enroll new monitoring agents with an edge onboarding token.
              </p>
            </div>
          </div>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Enroll Agent</div>
            </:header>
            <div class="p-6 space-y-6">
              <p class="text-base-content/70">
                Agents connect directly to the agent-gateway over gRPC with mTLS. Use an
                onboarding package to enroll the agent and write its bootstrap config.
              </p>

              <div class="card bg-base-200/50 p-4 space-y-3">
                <div class="flex items-center gap-2">
                  <.icon name="hero-server" class="size-5 text-primary" />
                  <h3 class="font-semibold">Agent Package</h3>
                </div>
                <p class="text-sm text-base-content/70">
                  Generate an onboarding package for a new agent. The token installs mTLS
                  credentials and points the agent at the gateway endpoint.
                </p>
                <div class="flex flex-col gap-2">
                  <.link
                    :if={@can_manage_edge}
                    navigate={~p"/admin/edge-packages/new?component_type=agent"}
                  >
                    <.ui_button variant="primary" size="sm" class="w-full">
                      <.icon name="hero-plus" class="size-4" /> Create Agent Package
                    </.ui_button>
                  </.link>
                  <.link :if={@can_manage_edge} navigate={~p"/admin/edge-packages"}>
                    <.ui_button variant="ghost" size="sm" class="w-full">
                      View existing packages
                    </.ui_button>
                  </.link>
                </div>
              </div>

              <div class="divider"></div>

              <h3 class="font-medium text-base-content">Deployment Steps</h3>
              <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/70">
                <li>Create an agent onboarding package</li>
                <li>Copy the edgepkg token from the success modal</li>
                <li>
                  Run
                  <code class="rounded bg-base-200 px-2 py-1 text-xs font-mono">
                    /usr/local/bin/serviceradar-cli enroll --token &lt;token&gt;
                  </code>
                  on the target host
                </li>
                <li>Confirm the agent appears in the Agents inventory</li>
              </ol>

              <p class="text-xs text-base-content/50">
                The gateway address is derived from your deployment configuration by default. In Helm
                installs, set
                <code class="rounded bg-base-200 px-1 py-0.5 text-xs font-mono">
                  webNg.gatewayAddress
                </code>
                when agents should use a dedicated gateway host.
              </p>

              <div class="flex items-center gap-2 text-xs text-base-content/50">
                <.icon name="hero-document-arrow-down" class="size-4" />
                <.link
                  href="https://github.com/carverauto/serviceradar/releases"
                  target="_blank"
                  rel="noopener"
                  class="link link-hover"
                >
                  Download releases from GitHub
                </.link>
              </div>
            </div>
          </.ui_panel>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end
end
