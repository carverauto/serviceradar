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

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Deploy Agent")

    {:ok, socket}
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
        <.settings_nav current_path="/settings/agents/deploy" />
        <.agents_nav current_path="/settings/agents/deploy" />

        <div class="space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-base-content">Deploy Agent</h1>
              <p class="text-sm text-base-content/60">
                Deploy new monitoring agents to your infrastructure.
              </p>
            </div>
          </div>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Deploy New Agent</div>
            </:header>
            <div class="p-6 space-y-6">
              <p class="text-base-content/70">
                Deploy monitoring agents to collect system metrics, run health checks,
                and integrate with your infrastructure.
              </p>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="card bg-base-200/50 p-4 space-y-3">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-server" class="size-5 text-primary" />
                    <h3 class="font-semibold">Standard Agent</h3>
                  </div>
                  <p class="text-sm text-base-content/70">
                    Deploy a gateway with embedded agent for standalone monitoring.
                    Best for servers that connect directly to the cloud.
                  </p>
                  <.link navigate={~p"/admin/edge-packages"}>
                    <.ui_button variant="primary" size="sm" class="w-full">
                      <.icon name="hero-plus" class="size-4" /> Create Agent Package
                    </.ui_button>
                  </.link>
                </div>

                <div class="card bg-base-200/50 p-4 space-y-3">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-building-office" class="size-5 text-secondary" />
                    <h3 class="font-semibold">Edge Site Agent</h3>
                  </div>
                  <p class="text-sm text-base-content/70">
                    Deploy agents that connect through a local NATS leaf server.
                    Best for remote sites with many agents.
                  </p>
                  <.link navigate={~p"/admin/edge-sites"}>
                    <.ui_button variant="outline" size="sm" class="w-full">
                      <.icon name="hero-globe-alt" class="size-4" /> Manage Edge Sites
                    </.ui_button>
                  </.link>
                </div>
              </div>

              <div class="divider"></div>

              <h3 class="font-medium text-base-content">Deployment Steps</h3>
              <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/70">
                <li>Create a component package (Gateway type includes embedded agent)</li>
                <li>Copy the one-liner install command or download the bundle</li>
                <li>Run the installer on your target host</li>
                <li>The agent will register automatically with TLS certificates</li>
                <li>Configure Sysmon profiles to target the new agent</li>
              </ol>

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
