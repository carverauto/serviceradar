defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.MapperJobForm do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperForms
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperOptions

  alias Phoenix.HTML.Form

  attr :form, :any, required: true
  attr :seeds_text, :string, default: ""
  attr :agents, :list, default: []
  attr :unifi_form, :any, required: true
  attr :unifi_present, :boolean, default: false
  attr :mikrotik, :map, default: %{}

  def render(assigns) do
    # Get current values for conditional rendering
    discovery_mode = Form.input_value(assigns.form, :discovery_mode) || "snmp_api"
    partition = Form.input_value(assigns.form, :partition) || "default"
    current_agent_id = Form.input_value(assigns.form, :agent_id) || ""

    agent_options = mapper_agent_options(assigns.agents, partition, current_agent_id)

    assigns =
      assigns
      |> assign(:unifi_form, assigns.unifi_form || empty_unifi_form())
      |> assign(:mikrotik, normalize_mikrotik_fields(assigns.mikrotik))
      |> assign(:discovery_mode, discovery_mode)
      |> assign(:show_api, discovery_mode in ["api", "snmp_api"])
      |> assign(:agent_options, agent_options)

    ~H"""
    <.form
      for={@form}
      id="mapper-job-form"
      phx-submit="save_mapper_job"
      phx-change="mapper_form_change"
      class="space-y-6"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <.input field={@form[:name]} type="text" label="Job Name" required />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
        <.input field={@form[:description]} type="text" label="Description" />
        <.input field={@form[:interval]} type="text" label="Interval (e.g. 15m, 2h)" required />
        <.input field={@form[:partition]} type="text" label="Partition" required />
        <.input
          field={@form[:agent_id]}
          type="select"
          label="Agent"
          options={@agent_options}
          prompt="Any agent in partition"
        />
        <.input
          field={@form[:discovery_mode]}
          type="select"
          label="Discovery Mode"
          options={[
            {"API & SNMP", "snmp_api"},
            {"SNMP Only", "snmp"},
            {"API Only", "api"}
          ]}
        />
        <.input
          field={@form[:discovery_type]}
          type="select"
          label="Discovery Type"
          options={[
            {"Full", "full"},
            {"Basic", "basic"},
            {"Interfaces", "interfaces"},
            {"Topology", "topology"}
          ]}
        />
        <.input field={@form[:concurrency]} type="number" label="Concurrency" />
        <.input field={@form[:timeout]} type="text" label="Timeout (e.g. 30s)" />
        <.input field={@form[:retries]} type="number" label="Retries" />
      </div>

      <div>
        <label class="text-sm font-medium text-sr-ink">Seed Targets</label>
        <.input
          name="seeds"
          type="textarea"
          value={@seeds_text}
          label="Seeds (one per line or comma-separated)"
          placeholder="10.0.0.0/24\n10.0.1.10\nhost.example.com"
        />
      </div>

      <div :if={@show_api} class="rounded-xl border border-sr-line p-4 space-y-4">
        <div class="grid gap-4 xl:grid-cols-2">
          <div class="rounded-lg border border-sr-line/80 bg-sr-surface p-4 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-semibold">UniFi Controller</h3>
                <p class="text-xs text-sr-muted">API discovery integration.</p>
              </div>
              <span class="text-xs text-sr-muted">
                <%= if @unifi_present do %>
                  API key stored
                <% else %>
                  No API key saved
                <% end %>
              </span>
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@unifi_form[:name]} type="text" label="Controller Name" />
              <.input
                field={@unifi_form[:base_url]}
                type="text"
                label="Controller URL"
                placeholder="https://controller:8443 or https://controller:8443/proxy/network/integration/v1"
              />
              <.input
                field={@unifi_form[:api_key]}
                type="password"
                label="API Key"
                placeholder={if(@unifi_present, do: "stored", else: "required")}
              />
              <.input
                field={@unifi_form[:insecure_skip_verify]}
                type="checkbox"
                label="Skip TLS Verification"
              />
            </div>
          </div>

          <div class="rounded-lg border border-sr-line/80 bg-sr-surface p-4 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-semibold">MikroTik RouterOS</h3>
                <p class="text-xs text-sr-muted">RouterOS REST API discovery integration.</p>
              </div>
              <span class="text-xs text-sr-muted">
                <%= if @mikrotik.password_present do %>
                  Password stored
                <% else %>
                  No password saved
                <% end %>
              </span>
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input
                type="text"
                name="mikrotik[name]"
                value={@mikrotik.name}
                label="Source Name"
              />
              <.input
                type="text"
                name="mikrotik[base_url]"
                value={@mikrotik.base_url}
                label="RouterOS URL"
                placeholder="https://router/rest"
              />
              <.input
                type="text"
                name="mikrotik[username]"
                value={@mikrotik.username}
                label="Username"
              />
              <.input
                type="password"
                name="mikrotik[password]"
                value=""
                label="Password"
                placeholder={if(@mikrotik.password_present, do: "stored", else: "required")}
              />
              <.input
                type="checkbox"
                name="mikrotik[insecure_skip_verify]"
                checked={@mikrotik.insecure_skip_verify}
                label="Skip TLS Verification"
              />
            </div>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <.ui_button type="submit" variant="primary">Save Discovery Job</.ui_button>
        <.link navigate={~p"/settings/networks/discovery"}>
          <.ui_button variant="ghost">Cancel</.ui_button>
        </.link>
      </div>
    </.form>
    """
  end
end
