defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive do
  @moduledoc """
  Network credential rules settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias Phoenix.HTML.Form
  alias ServiceRadar.Credentials.CredentialRuleConsumers
  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Credentials.SshPrivateKeyCredential
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.PluginConfigForm
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/credentials"
  @built_in_providers ~w(proxmox unifi-protect axis)
  @auth_methods ~w(proxmox_api_token ssh_private_key username_password api_key certificate opaque)a
  @purposes ~w(inventory_enrichment console_access discovery generic camera_inventory camera_stream device_inventory)a
  @scope_types ~w(agent gateway partition)a
  @tls_policies ~w(verify skip_verify)a
  @ssh_host_key_policies ~w(known_hosts trust_on_first_use skip_verify)a
  @auth_method_atoms Map.new(@auth_methods, &{Atom.to_string(&1), &1})
  @purpose_atoms Map.new(@purposes, &{Atom.to_string(&1), &1})
  @scope_type_atoms Map.new(@scope_types, &{Atom.to_string(&1), &1})

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "Credential Rules")
       |> assign(:current_path, @current_path)
       |> assign(:rules, [])
       |> assign(:secrets, [])
       |> assign(:secret_options, [])
       |> assign(:secret_names, %{})
       |> assign(:integration_profiles, %{})
       |> assign(:integration_schedules, %{})
       |> assign(:agent_options, [])
       |> assign(:loading?, true)
       |> assign(:form_mode, nil)
       |> assign(:editing_rule, nil)
       |> assign(:rule_preview, nil)
       |> assign(:expanded_rule_id, nil)
       |> assign(:rule_consumers, nil)
       |> assign(:secret_form, nil)
       |> assign(:rule_form, rule_form(default_rule_params()))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage credential rules")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:current_path, @current_path)
      |> assign(:form_mode, socket.assigns.live_action)

    if connected?(socket) do
      {:noreply, load_page(socket, params)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_rule", %{"credential_rule" => params}, socket) do
    case normalize_rule_params(params, socket.assigns.integration_profiles) do
      {:ok, attrs} ->
        save_rule(socket, attrs)

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:rule_form, rule_form(params))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("change_rule", %{"credential_rule" => params}, socket) do
    normalized = normalize_rule_form_params(params, socket.assigns.integration_profiles)
    {:noreply, assign(socket, :rule_form, rule_form(normalized))}
  end

  def handle_event("disable_rule", %{"id" => id}, socket) do
    update_enabled(socket, id, :disable, "Credential rule disabled")
  end

  def handle_event("enable_rule", %{"id" => id}, socket) do
    update_enabled(socket, id, :enable, "Credential rule enabled")
  end

  def handle_event("test_rule", %{"id" => id}, socket) do
    case NetworkCredentialRule.dispatch_proxmox_api_test(id, scope: socket.assigns.current_scope) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential test dispatched: #{Map.get(result, :command_id)}")
         |> load_page(%{})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Credential test failed: #{format_error(reason)}")}
    end
  end

  def handle_event("run_integration_now", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Map.get(socket.assigns.integration_schedules, to_string(id)) do
      %ProducerSchedule{} = schedule ->
        case schedule
             |> Ash.Changeset.for_update(:run_now, %{}, scope: scope)
             |> Ash.update(scope: scope) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Inventory refresh dispatched")
             |> assign(
               :integration_schedules,
               Map.put(socket.assigns.integration_schedules, to_string(id), updated)
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Inventory refresh could not be dispatched")}
        end

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The plugin schedule is not provisioned yet; wait for credential reconciliation"
         )}
    end
  end

  def handle_event("preview_rule", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %NetworkCredentialRule{} = rule <- Enum.find(socket.assigns.rules, &(to_string(&1.id) == to_string(id))),
         {:ok, preview} <-
           NetworkCredentialRulePreview.preview_rule(rule,
             resolver: credential_preview_resolver(),
             query_opts: [scope: scope],
             other_rules: socket.assigns.rules,
             sample_limit: 5
           ) do
      effective =
        PluginAssignmentMaterializer.dry_run_rule(rule,
          resolver: credential_preview_resolver(),
          query_opts: [scope: scope],
          target_limit: 50
        )

      {:noreply, assign(socket, :rule_preview, %{rule: rule, preview: preview, effective: effective})}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Credential rule not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview failed: #{format_error(reason)}")}
    end
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :rule_preview, nil)}
  end

  def handle_event("toggle_consumers", %{"id" => id}, socket) do
    if to_string(socket.assigns.expanded_rule_id) == to_string(id) do
      {:noreply,
       socket
       |> assign(:expanded_rule_id, nil)
       |> assign(:rule_consumers, nil)}
    else
      case CredentialRuleConsumers.list_for_rule(to_string(id)) do
        {:ok, consumers} ->
          {:noreply,
           socket
           |> assign(:expanded_rule_id, to_string(id))
           |> assign(:rule_consumers, consumers)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to load consumers: #{format_error(reason)}")}
      end
    end
  end

  def handle_event("new_proxmox_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_secret_params()))}
  end

  def handle_event("new_ssh_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_ssh_secret_params()))}
  end

  def handle_event("new_api_key_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_api_key_secret_params()))}
  end

  def handle_event("new_awx_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_awx_secret_params()))}
  end

  def handle_event("new_username_password_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_username_password_secret_params()))}
  end

  def handle_event("new_rule_secret", _params, socket) do
    provider = form_string(socket.assigns.rule_form, :provider)
    auth_method = form_string(socket.assigns.rule_form, :auth_method)

    {:noreply, assign(socket, :secret_form, secret_form(default_secret_params_for_rule(provider, auth_method)))}
  end

  def handle_event("close_secret_form", _params, socket) do
    {:noreply, assign(socket, :secret_form, nil)}
  end

  def handle_event("save_secret", %{"credential_secret" => params}, socket) do
    case normalize_secret_params(params) do
      {:ok, attrs} ->
        save_secret(socket, attrs)

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:secret_form, secret_form(params))
         |> put_flash(:error, message)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:provider_options, provider_options(assigns.integration_profiles))
      |> assign(:integration_profile_list, integration_profile_list(assigns.integration_profiles))
      |> assign(:auth_methods, @auth_methods)
      |> assign(:purposes, @purposes)
      |> assign(:scope_types, @scope_types)
      |> assign(:tls_policies, @tls_policies)
      |> assign(:ssh_host_key_policies, @ssh_host_key_policies)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">Credential Rules</h1>
              <p class="mt-1 text-sm text-base-content/70">
                Scoped rules bind a provider secret to SRQL-matched targets and materialize plugin
                inputs — Proxmox VE inventory and console, UniFi Protect and Axis camera inventory
                and streams — without baking hosts or secrets into plugin configs.
                <a
                  class="link link-primary"
                  href="https://docs.serviceradar.cloud/docs/proxmox#console-access"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Read the Proxmox setup guide
                </a>
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <div class="dropdown dropdown-end">
                <div tabindex="0" role="button" class="btn btn-ghost btn-sm">New Secret</div>
                <ul
                  tabindex="0"
                  class="dropdown-content menu bg-base-100 rounded-box z-[1] w-60 p-2 shadow border border-base-200"
                >
                  <li>
                    <button type="button" phx-click="new_proxmox_secret">Proxmox API Token</button>
                  </li>
                  <li>
                    <button type="button" phx-click="new_api_key_secret">API Key</button>
                  </li>
                  <li>
                    <button type="button" phx-click="new_awx_secret">AWX API Token</button>
                  </li>
                  <li>
                    <button type="button" phx-click="new_username_password_secret">
                      Username &amp; Password
                    </button>
                  </li>
                  <li>
                    <button type="button" phx-click="new_ssh_secret">SSH Private Key</button>
                  </li>
                </ul>
              </div>
              <div class="dropdown dropdown-end">
                <div tabindex="0" role="button" class="btn btn-primary btn-sm">New Rule</div>
                <ul
                  tabindex="0"
                  class="dropdown-content menu bg-base-100 rounded-box z-[1] w-60 p-2 shadow border border-base-200"
                >
                  <li>
                    <.link navigate={~p"/settings/networks/credentials/new"}>Proxmox VE</.link>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/networks/credentials/new?provider=unifi-protect"}>
                      UniFi Protect
                    </.link>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/networks/credentials/new?provider=axis"}>
                      Axis (VAPIX)
                    </.link>
                  </li>
                  <li :for={profile <- @integration_profile_list}>
                    <.link navigate={
                      ~p"/settings/networks/credentials/new?provider=#{profile["provider"]}"
                    }>
                      {profile["label"]}
                    </.link>
                  </li>
                </ul>
              </div>
            </div>
          </div>

          <div class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Provider</th>
                    <th>Purpose</th>
                    <th>Scope</th>
                    <th>Runtime</th>
                    <th>Secret</th>
                    <th>Priority</th>
                    <th>Status</th>
                    <th>Last Activity</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@loading?}>
                    <td colspan="10" class="py-8 text-center text-sm text-base-content/60">
                      Loading credential rules.
                    </td>
                  </tr>
                  <tr :if={!@loading? and @rules == []}>
                    <td colspan="10" class="py-8 text-center text-sm text-base-content/60">
                      No credential rules found.
                    </td>
                  </tr>
                  <%= for rule <- @rules do %>
                    <tr>
                      <td class="font-medium">{rule.name}</td>
                      <td>{rule.provider}</td>
                      <td>{format_purposes(rule)}</td>
                      <td>{format_scope(rule)}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          runtime_badge_class(rule, @integration_profiles, @integration_schedules)
                        ]}>
                          {runtime_label(rule, @integration_profiles, @integration_schedules)}
                        </span>
                      </td>
                      <td>{Map.get(@secret_names, rule.secret_id, "Unknown")}</td>
                      <td>{rule.priority}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          if(rule.enabled, do: "badge-success", else: "badge-ghost")
                        ]}>
                          {if rule.enabled, do: "Enabled", else: "Disabled"}
                        </span>
                      </td>
                      <td>{runtime_status(rule, @integration_profiles, @integration_schedules)}</td>
                      <td>
                        <div class="flex justify-end gap-2">
                          <button
                            :if={plugin_integration_provider?(rule.provider, @integration_profiles)}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="run_integration_now"
                            phx-value-id={rule.id}
                            disabled={!Map.has_key?(@integration_schedules, to_string(rule.id))}
                          >
                            Run Now
                          </button>
                          <button
                            :if={testable_rule?(rule)}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="test_rule"
                            phx-value-id={rule.id}
                          >
                            Test
                          </button>
                          <span
                            :if={
                              !testable_rule?(rule) and
                                !plugin_integration_provider?(rule.provider, @integration_profiles)
                            }
                            class="tooltip tooltip-left"
                            data-tip="Credential test is not yet available for this provider"
                          >
                            <button type="button" class="btn btn-ghost btn-xs btn-disabled" disabled>
                              Test
                            </button>
                          </span>
                          <button
                            :if={!plugin_integration_provider?(rule.provider, @integration_profiles)}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="preview_rule"
                            phx-value-id={rule.id}
                          >
                            Preview
                          </button>
                          <button
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="toggle_consumers"
                            phx-value-id={rule.id}
                          >
                            Consumers
                          </button>
                          <.link
                            navigate={~p"/settings/networks/credentials/#{rule.id}/edit"}
                            class="btn btn-ghost btn-xs"
                          >
                            Edit
                          </.link>
                          <button
                            :if={rule.enabled}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="disable_rule"
                            phx-value-id={rule.id}
                          >
                            Disable
                          </button>
                          <button
                            :if={!rule.enabled}
                            type="button"
                            class="btn btn-ghost btn-xs"
                            phx-click="enable_rule"
                            phx-value-id={rule.id}
                          >
                            Enable
                          </button>
                        </div>
                      </td>
                    </tr>
                    <tr :if={@expanded_rule_id == to_string(rule.id)} class="bg-base-200/40">
                      <td colspan="10">
                        <.rule_consumers_panel consumers={@rule_consumers} />
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <.rule_form_modal
          :if={@form_mode in [:new, :edit]}
          form={@rule_form}
          mode={@form_mode}
          secrets={@secrets}
          provider_options={@provider_options}
          integration_profiles={@integration_profiles}
          auth_methods={@auth_methods}
          purposes={@purposes}
          scope_types={@scope_types}
          agent_options={@agent_options}
          tls_policies={@tls_policies}
          ssh_host_key_policies={@ssh_host_key_policies}
        />

        <.rule_preview_modal :if={@rule_preview} rule_preview={@rule_preview} />
        <.secret_form_modal :if={@secret_form} form={@secret_form} tls_policies={@tls_policies} />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :tls_policies, :list, required: true

  defp secret_form_modal(assigns) do
    assigns =
      assigns
      |> assign(:secret_kind, form_string(assigns.form, :kind))
      |> assign(:secret_title, secret_form_title(form_string(assigns.form, :kind)))

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-3xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">{@secret_title}</h2>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_secret_form">
            Close
          </button>
        </div>

        <.form for={@form} phx-submit="save_secret" class="space-y-4">
          <input type="hidden" name={@form[:kind].name} value={@secret_kind} />

          <div :if={@secret_kind == "proxmox_api_token"} class="space-y-4">
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
              <.input field={@form[:user]} label="User" required />
              <.input field={@form[:realm]} label="Realm" required />
              <.input field={@form[:token_id]} label="Token ID" required />
              <.input
                field={@form[:tls_policy]}
                type="select"
                label="TLS Policy"
                options={enum_options([:verify])}
                required
              />
            </div>

            <.input field={@form[:token_secret]} type="password" label="Token Secret" required />
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div :if={@secret_kind == "api_key"} class="space-y-4">
            <div class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80">
              Store a provider API key (for example a UniFi Protect API key). The key is
              encrypted at rest; credential rules deliver it to matching plugins as a secret
              reference, never inline.
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
              <.input field={@form[:provider]} label="Provider" required />
            </div>

            <.input field={@form[:api_key]} type="password" label="API Key" required />
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div :if={@secret_kind == "awx_api_token"} class="space-y-4">
            <div class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80">
              Store an AWX/AAP OAuth2 bearer token under the <span class="font-mono">awx</span>
              provider. The token is encrypted at rest; the credential broker injects it as an
              <span class="font-mono">Authorization: Bearer</span>
              header when an Ansible controller dispatches — no token is baked into config.
              Reference this secret from <span class="font-mono">Settings → Ansible → Controllers</span>.
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
            </div>

            <.input field={@form[:api_token]} type="password" label="AWX API Token" required />
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div :if={@secret_kind == "username_password"} class="space-y-4">
            <div class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80">
              Store a provider username and password (for example an Axis VAPIX or UniFi Protect
              local account). The password is encrypted at rest; only the username is delivered
              in plain text to matching plugins.
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
              <.input field={@form[:provider]} label="Provider" required />
              <.input field={@form[:username]} label="Username" required />
              <.input field={@form[:password]} type="password" label="Password" required />
            </div>

            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div :if={@secret_kind == "ssh_private_key"} class="space-y-4">
            <div class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80">
              Store the PVE host SSH key used by console access rules. The private key is encrypted
              with AshCloak and only injected into the scoped agent config for matching console
              sessions.
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
              <.input field={@form[:username]} label="Username" required />
              <.input field={@form[:passphrase]} type="password" label="Passphrase" />
            </div>

            <.input field={@form[:private_key]} type="textarea" label="Private Key" required />
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_secret_form">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Save
            </button>
          </div>
        </.form>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_secret_form">Close</button>
    </div>
    """
  end

  attr :consumers, :map, default: nil

  defp rule_consumers_panel(assigns) do
    ~H"""
    <div class="space-y-2 p-2 text-xs">
      <%= cond do %>
        <% is_nil(@consumers) -> %>
          <p class="text-base-content/60">Loading consumers.</p>
        <% @consumers.total == 0 -> %>
          <p class="text-base-content/60">
            No materialized plugin assignments yet — the reconciler has not produced assignments
            for this rule. Check that the rule is enabled and that its scope, purposes, and
            target query match connected agents.
          </p>
        <% true -> %>
          <p class="text-base-content/70">
            Materializes {@consumers.total} assignment(s)
            ({@consumers.enabled_count} enabled) across {length(@consumers.agent_uids)} agent(s).
            Last materialized {format_timestamp(@consumers.last_materialized_at)}.
          </p>
          <div class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>Agent</th>
                  <th>Plugin</th>
                  <th>Purpose</th>
                  <th>Status</th>
                  <th>Last Materialized</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={consumer <- @consumers.consumers}>
                  <td class="font-mono">{consumer.agent_uid}</td>
                  <td class="font-mono">{consumer.plugin_id}</td>
                  <td>{consumer.purpose}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      if(consumer.enabled, do: "badge-success", else: "badge-ghost")
                    ]}>
                      {if consumer.enabled, do: "enabled", else: "disabled"}
                    </span>
                  </td>
                  <td>{format_timestamp(consumer.last_materialized_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
      <% end %>
    </div>
    """
  end

  attr :rule_preview, :map, required: true

  defp rule_preview_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-5xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">Target Preview</h2>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_preview">
            Close
          </button>
        </div>

        <div class="space-y-4">
          <div class="grid gap-3 md:grid-cols-4">
            <div class="rounded-lg border border-base-200 p-3">
              <div class="text-xs text-base-content/60">Matched</div>
              <div class="text-xl font-semibold">{@rule_preview.preview.matched_devices}</div>
            </div>
            <div class="rounded-lg border border-base-200 p-3">
              <div class="text-xs text-base-content/60">In Scope</div>
              <div class="text-xl font-semibold">{@rule_preview.preview.scoped_devices}</div>
            </div>
            <div class="rounded-lg border border-base-200 p-3">
              <div class="text-xs text-base-content/60">Agents</div>
              <div class="text-xl font-semibold">{length(@rule_preview.preview.agents)}</div>
            </div>
            <div class="rounded-lg border border-base-200 p-3">
              <div class="text-xs text-base-content/60">Conflicts</div>
              <div class="text-xl font-semibold">{length(@rule_preview.preview.conflicts)}</div>
            </div>
          </div>

          <div class="grid gap-4 lg:grid-cols-2">
            <section class="space-y-2">
              <h3 class="text-sm font-semibold">Agent Distribution</h3>
              <div class="overflow-hidden rounded-lg border border-base-200">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th class="text-right">Devices</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@rule_preview.preview.agents == []}>
                      <td colspan="2" class="py-4 text-center text-sm text-base-content/60">
                        No in-scope agents.
                      </td>
                    </tr>
                    <tr :for={agent <- @rule_preview.preview.agents}>
                      <td>{agent.agent_id}</td>
                      <td class="text-right">{agent.device_count}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section class="space-y-2">
              <h3 class="text-sm font-semibold">Sample Devices</h3>
              <div class="overflow-hidden rounded-lg border border-base-200">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Device</th>
                      <th>Address</th>
                      <th>Agent</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@rule_preview.preview.sample_devices == []}>
                      <td colspan="3" class="py-4 text-center text-sm text-base-content/60">
                        No in-scope devices.
                      </td>
                    </tr>
                    <tr :for={device <- @rule_preview.preview.sample_devices}>
                      <td>{device_label(device)}</td>
                      <td>{device_address(device)}</td>
                      <td>{device_agent(device)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          </div>

          <section :if={@rule_preview.preview.conflicts != []} class="space-y-2">
            <h3 class="text-sm font-semibold text-error">Credential Conflicts</h3>
            <div class="overflow-hidden rounded-lg border border-error/30">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Rule</th>
                    <th>Priority</th>
                    <th class="text-right">Overlapping Devices</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={conflict <- @rule_preview.preview.conflicts}>
                    <td>{conflict.rule_id}</td>
                    <td>{conflict.priority}</td>
                    <td class="text-right">{conflict.overlapping_devices}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section class="space-y-2">
            <h3 class="text-sm font-semibold">Effective Inputs (dry run)</h3>
            <%= case Map.get(@rule_preview, :effective) do %>
              <% {:ok, effective} -> %>
                <p class="text-xs text-base-content/60">
                  {effective.targets.total} target(s) resolved from the rule's SRQL query
                  <span :if={effective.targets.truncated?}>
                    (showing first {length(effective.targets.sample)})
                  </span>
                  — secret references shown as-is; secret material is never resolved or displayed.
                </p>
                <div
                  :for={entry <- effective.purposes}
                  class="rounded-lg border border-base-200 p-3 space-y-2"
                >
                  <div class="flex flex-wrap items-center gap-2 text-xs">
                    <span class="badge badge-ghost badge-sm">{entry.purpose}</span>
                    <span class="font-mono">{entry.plugin_id}</span>
                    <span class="font-mono text-base-content/60">{entry.policy_id}</span>
                    <span :if={!entry.package_found?} class="badge badge-warning badge-sm">
                      no approved package
                    </span>
                    <span class="text-base-content/60">
                      every {entry.interval_seconds}s, timeout {entry.timeout_seconds}s
                    </span>
                  </div>
                  <pre class="max-h-64 overflow-auto rounded bg-base-200/60 p-2 text-[11px] font-mono"><%= encode_json(entry.params_template) %></pre>
                </div>
                <div
                  :if={effective.targets.sample != []}
                  class="overflow-hidden rounded-lg border border-base-200"
                >
                  <table class="table table-xs">
                    <thead>
                      <tr>
                        <th>Target</th>
                        <th>Address</th>
                        <th>Agent</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={device <- effective.targets.sample}>
                        <td>{device_label(device)}</td>
                        <td>{device_address(device)}</td>
                        <td>{device_agent(device)}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% {:error, reason} -> %>
                <p class="text-xs text-error">Dry run failed: {format_error(reason)}</p>
              <% _ -> %>
                <p class="text-xs text-base-content/60">Dry run unavailable.</p>
            <% end %>
          </section>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_preview">Close</button>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :mode, :atom, required: true
  attr :secrets, :list, required: true
  attr :provider_options, :list, required: true
  attr :integration_profiles, :map, required: true
  attr :auth_methods, :list, required: true
  attr :purposes, :list, required: true
  attr :scope_types, :list, required: true
  attr :agent_options, :list, required: true
  attr :tls_policies, :list, required: true
  attr :ssh_host_key_policies, :list, required: true

  defp rule_form_modal(assigns) do
    assigns =
      assigns
      |> assign(:scope_type_value, form_string(assigns.form, :scope_type))
      |> assign(:provider_value, form_string(assigns.form, :provider))
      |> assign(:auth_method_value, form_string(assigns.form, :auth_method))

    integration_profile = Map.get(assigns.integration_profiles, assigns.provider_value)

    assigns =
      assigns
      |> assign(:integration_profile, integration_profile)
      |> assign(:plugin_integration?, is_map(integration_profile))
      |> assign(:plugin_config_params, form_plugin_config(assigns.form))
      |> assign(
        :provider_auth_methods,
        provider_auth_methods(assigns.provider_value, assigns.integration_profiles)
      )
      |> assign(
        :provider_purposes,
        provider_purposes(assigns.provider_value, assigns.integration_profiles)
      )
      |> assign(
        :provider_scope_types,
        provider_scope_types(assigns.provider_value, assigns.integration_profiles)
      )
      |> assign(:camera_provider?, camera_provider?(assigns.provider_value))
      |> assign(:show_ssh_policy?, assigns.auth_method_value == "ssh_private_key")
      |> assign(:show_auto_discovery?, assigns.provider_value == "proxmox")
      |> assign(:show_controller_host?, assigns.provider_value == "unifi-protect")
      |> assign(
        :secret_options_for_rule,
        secret_options_for(
          assigns.secrets,
          assigns.provider_value,
          assigns.auth_method_value,
          form_string(assigns.form, :secret_id)
        )
      )

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">
            {if @mode == :new, do: "New Credential Rule", else: "Edit Credential Rule"}
          </h2>
          <.link navigate={~p"/settings/networks/credentials"} class="btn btn-ghost btn-sm">
            Close
          </.link>
        </div>

        <.form
          for={@form}
          id="credential-rule-form"
          phx-change="change_rule"
          phx-submit="save_rule"
          class="space-y-4"
        >
          <div class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-base-content/80">
            <span :if={@provider_value == "proxmox"}>
              Inventory and console access are separate credential purposes. Select console access
              explicitly, then restrict which users may invoke the credential below. A Proxmox API
              token can support native PVE console proxy sessions without a separate SSH key, but an
              inventory-only token is never console-eligible. Runtime fields such as <span class="font-mono">credential_broker</span>, <span class="font-mono">credential_rule_id</span>, and
              <span class="font-mono">console</span>
              are generated by ServiceRadar when a console session starts.
              <a
                class="link link-primary"
                href="https://docs.serviceradar.cloud/docs/proxmox#console-access"
                target="_blank"
                rel="noopener noreferrer"
              >
                Configuration guide
              </a>
            </span>
            <span :if={@provider_value in ["unifi-protect", "axis"]}>
              Camera rules materialize plugin inputs per matched device: the controller or camera
              host comes from the SRQL target query, so no host is stored in the plugin config.
              UniFi Protect accepts <span class="font-mono">api_key</span>
              or username/password auth; Axis (VAPIX) uses username/password. Choose <span class="font-mono">camera_inventory</span>, <span class="font-mono">camera_stream</span>,
              or both. Runtime fields such as <span class="font-mono">credential_broker</span>
              and <span class="font-mono">credential_rule_id</span>
              are generated when the rule materializes.
            </span>
            <span :if={@plugin_integration?}>
              {@integration_profile["description"] || @integration_profile["label"]} Configuration is owned by the approved plugin package. Credentials are resolved into
              short-lived grants for each scheduled or manual run.
            </span>
            <span :if={
              !@plugin_integration? and @provider_value not in ["proxmox", "unifi-protect", "axis"]
            }>
              Select every use this scoped credential should allow. Enabled rules materialize
              plugin inputs for agents in scope; runtime fields such as
              <span class="font-mono">credential_broker</span>
              and <span class="font-mono">credential_rule_id</span>
              are generated by ServiceRadar.
            </span>
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@form[:name]} label="Name" required />
            <.input
              field={@form[:provider]}
              type="select"
              label="Provider"
              options={@provider_options}
              required
            />
            <.input field={@form[:priority]} type="number" label="Priority" min="0" required />
            <div class="space-y-2">
              <.input
                field={@form[:secret_id]}
                type="select"
                label="Secret"
                options={@secret_options_for_rule}
                prompt="Select a secret"
                required
              />
              <button
                id="credential-rule-new-secret"
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="new_rule_secret"
              >
                New secret for this rule
              </button>
            </div>
            <.input
              field={@form[:auth_method]}
              type="select"
              label="Auth Method"
              options={enum_options(@provider_auth_methods)}
              required
            />
            <fieldset class="rounded-lg border border-base-300 p-3 md:col-span-2">
              <legend class="px-1 text-sm font-medium">Purpose</legend>
              <input type="hidden" name="credential_rule[purposes][]" value="" />
              <div class="grid gap-2 sm:grid-cols-2">
                <label
                  :for={purpose <- @provider_purposes}
                  class="flex items-center gap-2 rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm"
                >
                  <input
                    type="checkbox"
                    name="credential_rule[purposes][]"
                    value={to_string(purpose)}
                    checked={to_string(purpose) in form_purposes(@form)}
                    class="checkbox checkbox-sm"
                  />
                  <span class="font-mono">{to_string(purpose)}</span>
                </label>
              </div>
            </fieldset>
            <fieldset
              :if={"console_access" in form_purposes(@form)}
              class="fieldset rounded-lg border border-base-300 p-3 md:col-span-2"
            >
              <legend class="fieldset-legend px-1">Console credential users</legend>
              <p class="label mb-2">
                At least one exact role, user/IdP subject, or IdP group is required. Selectors are
                combined with OR; ServiceRadar rechecks them when the console stream attaches.
              </p>
              <div class="grid gap-3 md:grid-cols-3">
                <.input
                  field={@form[:credential_use_roles]}
                  label="Allowed roles"
                  placeholder="admin"
                />
                <.input
                  field={@form[:credential_use_principals]}
                  label="Allowed users or subjects"
                  placeholder="user UUID, IdP subject"
                />
                <.input
                  field={@form[:credential_use_groups]}
                  label="Allowed IdP groups"
                  placeholder="pve-console-operators"
                />
              </div>
              <p class="label">Separate multiple selectors with commas or new lines.</p>
            </fieldset>
            <.input
              :if={!@plugin_integration?}
              field={@form[:scope_type]}
              type="select"
              label="Scope Type"
              options={enum_options(@provider_scope_types)}
              required
            />
            <input
              :if={@plugin_integration?}
              type="hidden"
              name={@form[:scope_type].name}
              value={List.first(@provider_scope_types)}
            />
            <input
              :if={@plugin_integration?}
              type="hidden"
              name={@form[:tls_policy].name}
              value="verify"
            />
            <.input
              :if={@scope_type_value == "agent" and @agent_options != []}
              field={@form[:scope_value]}
              type="select"
              label="Scope Value"
              options={@agent_options}
              prompt="Select an agent"
              required
            />
            <.input
              :if={@scope_type_value != "agent" or @agent_options == []}
              field={@form[:scope_value]}
              label="Scope Value"
              required
            />
            <.input
              :if={@show_controller_host?}
              field={@form[:controller_host]}
              label="Controller Host Override"
            />
            <.input
              :if={!@plugin_integration?}
              field={@form[:tls_policy]}
              type="select"
              label="TLS Policy"
              options={
                enum_options(if @provider_value == "proxmox", do: [:verify], else: @tls_policies)
              }
              required
            />
            <.input
              :if={@show_ssh_policy?}
              field={@form[:ssh_host_key_policy]}
              type="select"
              label="SSH Host Key Policy"
              options={enum_options([:known_hosts, :trust_on_first_use])}
              required
            />
          </div>

          <input
            :if={@plugin_integration?}
            type="hidden"
            name={@form[:target_query].name}
            value="in:agents"
          />
          <.input
            :if={!@plugin_integration?}
            field={@form[:target_query]}
            type="textarea"
            label="Target Query"
            required
          />
          <fieldset :if={@plugin_integration?} class="space-y-4 border-t border-base-200 pt-4">
            <legend class="text-sm font-semibold">{@integration_profile["label"]}</legend>
            <PluginConfigForm.plugin_config_fields
              schema={@integration_profile["config_schema"]}
              params={@plugin_config_params}
              base_name="credential_rule[plugin_config]"
              docs_url={get_in(@integration_profile, ["documentation", "url"])}
            />
            <div class="grid gap-4 md:grid-cols-2">
              <.input
                field={@form[:cadence_seconds]}
                type="number"
                label="Cadence (seconds)"
                min={@integration_profile["producer_schedule"]["min_cadence_seconds"]}
                max={@integration_profile["producer_schedule"]["max_cadence_seconds"]}
                required
              />
              <.input
                field={@form[:schedule_enabled]}
                type="checkbox"
                label="Enable recurring inventory refresh"
              />
            </div>
          </fieldset>
          <.input
            :if={@show_auto_discovery?}
            field={@form[:auto_discovery_enabled]}
            type="checkbox"
            label="Allow auto-discovery credential trials"
          />
          <.input :if={!@plugin_integration?} field={@form[:allowed_ports]} label="Allowed Ports" />
          <.input field={@form[:description]} type="textarea" label="Description" />

          <div class="modal-action">
            <.link navigate={~p"/settings/networks/credentials"} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              Save
            </button>
          </div>
        </.form>
      </div>
      <.link navigate={~p"/settings/networks/credentials"} class="modal-backdrop">Close</.link>
    </div>
    """
  end

  defp load_page(socket, params) do
    socket = reload_page_data(socket)

    case socket.assigns.form_mode do
      :new ->
        defaults = default_rule_params(params, socket.assigns.integration_profiles)
        assign(socket, :rule_form, rule_form(defaults))

      :edit ->
        assign_edit_form(socket, params["id"], socket.assigns.rules)

      _ ->
        socket
        |> assign(:editing_rule, nil)
        |> assign(:rule_form, rule_form(default_rule_params()))
    end
  end

  defp reload_page_data(socket) do
    scope = socket.assigns.current_scope

    integration_profiles = load_integration_profiles()
    rules = load_rules(scope)
    secrets = load_secrets(scope)
    agents = load_agents(scope)
    integration_schedules = load_integration_schedules(scope, integration_profiles)

    secret_names = Map.new(secrets, &{&1.id, secret_label(&1)})

    socket
    |> assign(:rules, rules)
    |> assign(:secrets, secrets)
    |> assign(:secret_options, Enum.map(secrets, &{secret_label(&1), &1.id}))
    |> assign(:secret_names, secret_names)
    |> assign(:integration_profiles, integration_profiles)
    |> assign(:integration_schedules, integration_schedules)
    |> assign(:agent_options, agent_options(agents))
    |> assign(:loading?, false)
  end

  defp assign_edit_form(socket, id, rules) do
    case Enum.find(rules, &(to_string(&1.id) == to_string(id))) do
      nil ->
        socket
        |> put_flash(:error, "Credential rule not found")
        |> push_patch(to: ~p"/settings/networks/credentials")

      rule ->
        socket
        |> assign(:editing_rule, rule)
        |> assign(:rule_form, rule_form(rule_params(rule)))
    end
  end

  defp save_rule(%{assigns: %{form_mode: :new}} = socket, attrs) do
    case NetworkCredentialRule
         |> Ash.Changeset.for_create(:create, attrs, scope: socket.assigns.current_scope)
         |> Ash.create(scope: socket.assigns.current_scope) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential rule created")
         |> push_patch(to: ~p"/settings/networks/credentials")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create rule: #{format_error(reason)}")}
    end
  end

  defp save_rule(%{assigns: %{form_mode: :edit, editing_rule: %NetworkCredentialRule{} = rule}} = socket, attrs) do
    attrs = merge_rule_metadata(rule, attrs)

    case rule
         |> Ash.Changeset.for_update(:update, attrs, scope: socket.assigns.current_scope)
         |> Ash.update(scope: socket.assigns.current_scope) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential rule saved")
         |> push_patch(to: ~p"/settings/networks/credentials")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save rule: #{format_error(reason)}")}
    end
  end

  defp save_rule(socket, _attrs) do
    {:noreply, put_flash(socket, :error, "Credential rule form is not ready")}
  end

  defp save_secret(socket, attrs) do
    case NetworkCredentialSecret
         |> Ash.Changeset.for_create(:create, attrs, scope: socket.assigns.current_scope)
         |> Ash.create(scope: socket.assigns.current_scope) do
      {:ok, secret} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credential secret saved")
         |> assign(:secret_form, nil)
         |> reload_page_data()
         |> maybe_select_rule_secret(secret)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save credential secret: #{format_error(reason)}")}
    end
  end

  defp update_enabled(socket, id, action, message) do
    scope = socket.assigns.current_scope

    with %NetworkCredentialRule{} = rule <- Enum.find(socket.assigns.rules, &(to_string(&1.id) == to_string(id))),
         {:ok, _rule} <-
           rule
           |> Ash.Changeset.for_update(action, %{}, scope: scope)
           |> Ash.update(scope: scope) do
      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_page(%{})}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Credential rule not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update rule: #{format_error(reason)}")}
    end
  end

  defp maybe_select_rule_secret(%{assigns: %{form_mode: mode, rule_form: form}} = socket, secret)
       when mode in [:new, :edit] do
    provider = form_string(form, :provider)
    auth_method = form_string(form, :auth_method)

    if secret_matches_rule?(secret, provider, auth_method) do
      params =
        form
        |> rule_form_params()
        |> Map.put("secret_id", to_string(secret.id))

      assign(socket, :rule_form, rule_form(params))
    else
      socket
    end
  end

  defp maybe_select_rule_secret(socket, _secret), do: socket

  defp rule_form_params(form) do
    %{
      "name" => form_string(form, :name),
      "description" => form_string(form, :description),
      "provider" => form_string(form, :provider),
      "auth_method" => form_string(form, :auth_method),
      "purpose" => form_string(form, :purpose),
      "purposes" => form_purposes(form),
      "target_query" => form_string(form, :target_query),
      "scope_type" => form_string(form, :scope_type),
      "scope_value" => form_string(form, :scope_value),
      "secret_id" => form_string(form, :secret_id),
      "priority" => form_string(form, :priority),
      "allowed_ports" => form_string(form, :allowed_ports),
      "tls_policy" => form_string(form, :tls_policy),
      "ssh_host_key_policy" => form_string(form, :ssh_host_key_policy),
      "auto_discovery_enabled" => form_string(form, :auto_discovery_enabled),
      "controller_host" => form_string(form, :controller_host),
      "plugin_config" => form_plugin_config(form),
      "schedule_enabled" => form_string(form, :schedule_enabled),
      "cadence_seconds" => form_string(form, :cadence_seconds)
    }
  end

  defp load_rules(scope) do
    NetworkCredentialRule
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rules} -> rules
      _ -> []
    end
  end

  defp load_secrets(scope) do
    NetworkCredentialSecret
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(provider: :asc, name: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, secrets} -> secrets
      _ -> []
    end
  end

  defp load_agents(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> Enum.filter(agents, &active_agent?/1)
      _ -> []
    end
  end

  defp load_integration_profiles do
    case IntegrationCatalog.load() do
      {:ok, catalog} -> Map.new(catalog.credential_profiles, &{&1["provider"], &1})
      {:error, _reason} -> %{}
    end
  end

  defp load_integration_schedules(scope, profiles) do
    schedule_ids =
      profiles
      |> Map.values()
      |> Enum.map(&get_in(&1, ["provisioning", "schedule_id"]))
      |> Enum.reject(&is_nil/1)

    ProducerSchedule
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(schedule_id in ^schedule_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, schedules} ->
        Enum.reduce(schedules, %{}, fn schedule, acc ->
          case schedule.metadata |> normalize_metadata() |> Map.get("credential_rule_id") do
            rule_id when is_binary(rule_id) and rule_id != "" ->
              Map.put(acc, rule_id, schedule)

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp active_agent?(%Agent{status: status, last_seen_time: %DateTime{} = last_seen_time})
       when status in [:connected, :degraded, :connecting] do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(%Agent{last_seen_time: %DateTime{} = last_seen_time}) do
    DateTime.diff(DateTime.utc_now(), last_seen_time, :minute) <= 30
  end

  defp active_agent?(_agent), do: false

  defp normalize_rule_params(params, integration_profiles) do
    providers = @built_in_providers ++ Map.keys(integration_profiles)

    with {:ok, provider} <- string_enum_param(params, "provider", providers, "provider"),
         {:ok, auth_method} <-
           enum_param(
             params,
             "auth_method",
             provider_auth_methods(provider, integration_profiles),
             "auth method"
           ),
         {:ok, purposes} <- purposes_param(params, provider, integration_profiles),
         {:ok, scope_type} <-
           enum_param(
             params,
             "scope_type",
             provider_scope_types(provider, integration_profiles),
             "scope type"
           ),
         :ok <- validate_provider_scope(provider, scope_type, integration_profiles),
         {:ok, tls_policy} <- enum_param(params, "tls_policy", @tls_policies, "TLS policy"),
         {:ok, ssh_policy} <- ssh_host_key_policy_param(params, auth_method),
         :ok <- validate_proxmox_transport(provider, auth_method, tls_policy, ssh_policy),
         {:ok, priority} <- integer_param(params, "priority", "priority"),
         {:ok, allowed_ports} <- allowed_ports(params["allowed_ports"]),
         {:ok, credential_use_policy} <- credential_use_policy_param(params, purposes),
         {:ok, metadata} <-
           rule_metadata(
             params,
             provider,
             purposes,
             Map.get(integration_profiles, provider),
             credential_use_policy
           ) do
      {:ok,
       %{
         name: required_string(params, "name"),
         description: blank_to_nil(params["description"]),
         provider: provider,
         auth_method: auth_method,
         purpose: primary_purpose(purposes),
         target_query: required_string(params, "target_query"),
         scope_type: scope_type,
         scope_value: required_string(params, "scope_value"),
         secret_id: required_string(params, "secret_id"),
         priority: priority,
         allowed_ports: allowed_ports,
         tls_policy: tls_policy,
         ssh_host_key_policy: ssh_policy,
         metadata: metadata
       }}
    end
  rescue
    ArgumentError -> {:error, "Required fields are missing"}
  end

  defp normalize_secret_params(%{"kind" => "ssh_private_key"} = params) do
    name = required_string(params, "name")
    username = required_string(params, "username")
    private_key = required_string(params, "private_key")

    SshPrivateKeyCredential.build_attrs(%{
      name: name,
      description: blank_to_nil(params["description"]),
      provider: "proxmox",
      username: username,
      private_key: private_key,
      passphrase: blank_to_nil(params["passphrase"]),
      metadata: %{
        "auth_method" => "ssh_private_key",
        "usage" => "console_access"
      }
    })
  rescue
    ArgumentError -> {:error, "Required SSH key fields are missing"}
  end

  defp normalize_secret_params(%{"kind" => "api_key"} = params) do
    name = required_string(params, "name")
    provider = required_string(params, "provider")
    api_key = required_string(params, "api_key")

    {:ok,
     %{
       name: name,
       description: blank_to_nil(params["description"]),
       provider: provider,
       credential_kind: :api_token,
       public_fingerprint: secret_fingerprint(api_key),
       secret_payload: api_key,
       metadata: %{
         "auth_method" => "api_key"
       }
     }}
  rescue
    ArgumentError -> {:error, "Required API key fields are missing"}
  end

  defp normalize_secret_params(%{"kind" => "awx_api_token"} = params) do
    name = required_string(params, "name")
    token = required_string(params, "api_token")

    {:ok,
     %{
       name: name,
       description: blank_to_nil(params["description"]),
       provider: "awx",
       credential_kind: :api_token,
       public_fingerprint: secret_fingerprint(token),
       secret_payload: token,
       last_rotated_at: DateTime.utc_now(),
       metadata: %{
         "auth_method" => "bearer_token",
         "source" => "credential_rules_form"
       }
     }}
  rescue
    ArgumentError -> {:error, "Required AWX token fields are missing"}
  end

  defp normalize_secret_params(%{"kind" => "username_password"} = params) do
    name = required_string(params, "name")
    provider = required_string(params, "provider")
    username = required_string(params, "username")
    password = required_string(params, "password")

    {:ok,
     %{
       name: name,
       description: blank_to_nil(params["description"]),
       provider: provider,
       credential_kind: :username_password,
       username: username,
       secret_payload: password,
       metadata: %{
         "auth_method" => "username_password"
       }
     }}
  rescue
    ArgumentError -> {:error, "Required username/password fields are missing"}
  end

  defp normalize_secret_params(params) do
    with {:ok, tls_policy} <- enum_param(params, "tls_policy", @tls_policies, "TLS policy"),
         :ok <- require_proxmox_tls_verification(tls_policy) do
      name = required_string(params, "name")
      user = required_string(params, "user")
      realm = required_string(params, "realm")
      token_id = required_string(params, "token_id")
      token_secret = required_string(params, "token_secret")
      token_identity = proxmox_token_identity(user, realm, token_id)
      token_payload = token_identity <> "=" <> token_secret

      {:ok,
       %{
         name: name,
         description: blank_to_nil(params["description"]),
         provider: "proxmox",
         credential_kind: :api_token,
         username: token_identity,
         public_fingerprint: secret_fingerprint(token_payload),
         secret_payload: token_payload,
         metadata: %{
           "realm" => realm,
           "token_id" => token_id,
           "tls_policy" => Atom.to_string(tls_policy),
           "auth_method" => "proxmox_api_token"
         }
       }}
    end
  rescue
    ArgumentError -> {:error, "Required token fields are missing"}
  end

  defp default_rule_params(params \\ %{}, integration_profiles \\ %{})

  defp default_rule_params(%{"provider" => provider} = params, integration_profiles) do
    case Map.get(integration_profiles, provider) do
      %{} = profile -> plugin_rule_defaults(profile)
      nil -> built_in_default_rule_params(params)
    end
  end

  defp default_rule_params(params, _integration_profiles), do: built_in_default_rule_params(params)

  defp built_in_default_rule_params(%{"purpose" => "console_access"}) do
    %{
      "name" => "",
      "description" => "",
      "provider" => "proxmox",
      "auth_method" => "ssh_private_key",
      "purpose" => "console_access",
      "purposes" => ["console_access"],
      "target_query" => ~s(in:devices type:"Hypervisor" vendor:"Proxmox"),
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "22",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "credential_use_roles" => "admin",
      "credential_use_principals" => "",
      "credential_use_groups" => "",
      "auto_discovery_enabled" => "false"
    }
  end

  defp built_in_default_rule_params(%{"provider" => "unifi-protect"}) do
    %{
      "name" => "",
      "description" => "",
      "provider" => "unifi-protect",
      "auth_method" => "api_key",
      "purpose" => "camera_inventory",
      "purposes" => ["camera_inventory", "camera_stream"],
      "target_query" => ~s(in:devices vendor:"Ubiquiti"),
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "443, 7447",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "auto_discovery_enabled" => "false"
    }
  end

  defp built_in_default_rule_params(%{"provider" => "axis"}) do
    %{
      "name" => "",
      "description" => "",
      "provider" => "axis",
      "auth_method" => "username_password",
      "purpose" => "camera_inventory",
      "purposes" => ["camera_inventory", "camera_stream"],
      "target_query" => ~s(in:devices vendor:"Axis"),
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "443, 554",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "auto_discovery_enabled" => "false"
    }
  end

  defp built_in_default_rule_params(_params) do
    %{
      "name" => "",
      "description" => "",
      "provider" => "proxmox",
      "auth_method" => "proxmox_api_token",
      "purpose" => "inventory_enrichment",
      "purposes" => ["inventory_enrichment", "console_access"],
      "target_query" => "in:devices metadata.proxmox_candidate:true",
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "8006",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "credential_use_roles" => "admin",
      "credential_use_principals" => "",
      "credential_use_groups" => "",
      "auto_discovery_enabled" => "false"
    }
  end

  defp plugin_rule_defaults(profile) do
    schedule = profile["producer_schedule"]
    purposes = profile["purposes"]

    %{
      "name" => "",
      "description" => "",
      "provider" => profile["provider"],
      "auth_method" => get_in(profile, ["auth_methods", Access.at(0), "id"]),
      "purpose" => List.first(purposes),
      "purposes" => purposes,
      "target_query" => "in:agents",
      "scope_type" => List.first(profile["scope_types"]),
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "auto_discovery_enabled" => "false",
      "plugin_config" => ConfigSchema.normalize_params(profile["config_schema"] || %{}, %{}),
      "schedule_enabled" => "false",
      "cadence_seconds" => to_string(schedule["default_cadence_seconds"])
    }
  end

  defp default_secret_params do
    %{
      "kind" => "proxmox_api_token",
      "name" => "",
      "description" => "",
      "user" => "root",
      "realm" => "pam",
      "token_id" => "",
      "tls_policy" => "verify",
      "token_secret" => ""
    }
  end

  defp default_api_key_secret_params do
    %{
      "kind" => "api_key",
      "name" => "",
      "description" => "",
      "provider" => "unifi-protect",
      "api_key" => ""
    }
  end

  defp default_awx_secret_params do
    %{
      "kind" => "awx_api_token",
      "name" => "",
      "description" => "",
      "provider" => "awx",
      "api_token" => ""
    }
  end

  defp default_username_password_secret_params do
    %{
      "kind" => "username_password",
      "name" => "",
      "description" => "",
      "provider" => "axis",
      "username" => "",
      "password" => ""
    }
  end

  defp default_secret_params_for_rule(_provider, "ssh_private_key"), do: default_ssh_secret_params()

  defp default_secret_params_for_rule(provider, "api_key") do
    Map.put(default_api_key_secret_params(), "provider", provider_for_secret(provider, "unifi-protect"))
  end

  defp default_secret_params_for_rule(provider, "username_password") do
    Map.put(default_username_password_secret_params(), "provider", provider_for_secret(provider, "axis"))
  end

  defp default_secret_params_for_rule(_provider, _auth_method), do: default_secret_params()

  defp provider_for_secret(provider, fallback) do
    provider = provider |> to_string() |> String.trim()
    if provider == "", do: fallback, else: provider
  end

  defp default_ssh_secret_params do
    %{
      "kind" => "ssh_private_key",
      "name" => "",
      "description" => "",
      "username" => "root",
      "private_key" => "",
      "passphrase" => ""
    }
  end

  defp rule_params(rule) do
    %{
      "name" => rule.name,
      "description" => rule.description || "",
      "provider" => rule.provider,
      "auth_method" => to_string(rule.auth_method),
      "purpose" => to_string(rule.purpose),
      "purposes" => rule_purposes(rule),
      "target_query" => rule.target_query,
      "scope_type" => to_string(rule.scope_type),
      "scope_value" => rule.scope_value,
      "secret_id" => to_string(rule.secret_id),
      "priority" => to_string(rule.priority),
      "allowed_ports" => Enum.join(rule.allowed_ports || [], ", "),
      "tls_policy" => to_string(rule.tls_policy),
      "ssh_host_key_policy" => to_string(rule.ssh_host_key_policy),
      "controller_host" => controller_host_from_metadata(rule.metadata),
      "credential_use_roles" => credential_policy_selectors(rule.metadata, "roles"),
      "credential_use_principals" => credential_policy_selectors(rule.metadata, "principals"),
      "credential_use_groups" => credential_policy_selectors(rule.metadata, "groups"),
      "auto_discovery_enabled" => auto_discovery_enabled?(rule),
      "plugin_config" => metadata_form_value(rule.metadata, "plugin_config", %{}),
      "schedule_enabled" => metadata_form_value(rule.metadata, "schedule_enabled", false),
      "cadence_seconds" => metadata_form_value(rule.metadata, "cadence_seconds", 86_400)
    }
  end

  defp normalize_rule_form_params(params, integration_profiles) when is_map(params) do
    provider = normalize_provider(Map.get(params, "provider"), integration_profiles)
    defaults = default_rule_params(%{"provider" => provider}, integration_profiles)
    auth_method = normalize_auth_method(provider, Map.get(params, "auth_method"), integration_profiles)

    purposes =
      normalize_form_purposes(
        provider,
        Map.get(params, "purposes", Map.get(params, "purpose")),
        integration_profiles
      )

    params
    |> Map.put("provider", provider)
    |> Map.put("auth_method", to_string(auth_method))
    |> Map.put("purposes", purposes)
    |> Map.put("purpose", List.first(purposes))
    |> Map.put_new("scope_type", "agent")
    |> Map.put_new("scope_value", "")
    |> Map.put_new("credential_use_roles", defaults["credential_use_roles"] || "admin")
    |> Map.put_new("credential_use_principals", "")
    |> Map.put_new("credential_use_groups", "")
    |> put_default_when_blank("target_query", defaults["target_query"])
    |> put_default_when_blank("allowed_ports", defaults["allowed_ports"])
    |> Map.put_new("controller_host", "")
    |> put_plugin_defaults(Map.get(integration_profiles, provider), defaults)
    |> maybe_clear_camera_only_fields(provider)
  end

  defp normalize_rule_form_params(_, integration_profiles), do: default_rule_params(%{}, integration_profiles)

  defp rule_form(params), do: to_form(params, as: :credential_rule)

  defp secret_form(params), do: to_form(params, as: :credential_secret)

  defp secret_form_title("ssh_private_key"), do: "New Console SSH Key"
  defp secret_form_title("api_key"), do: "New API Key Secret"
  defp secret_form_title("awx_api_token"), do: "New AWX API Token"
  defp secret_form_title("username_password"), do: "New Username & Password Secret"
  defp secret_form_title(_kind), do: "New Proxmox Token"

  defp provider_auth_methods(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile ->
        Enum.map(profile["auth_methods"], &Map.fetch!(@auth_method_atoms, &1["id"]))

      nil ->
        case to_string(provider) do
          "unifi-protect" -> [:api_key, :username_password]
          "axis" -> [:username_password]
          _ -> [:proxmox_api_token, :ssh_private_key]
        end
    end
  end

  defp provider_purposes(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile ->
        Enum.map(profile["purposes"], &Map.fetch!(@purpose_atoms, &1))

      nil ->
        if camera_provider?(provider) do
          [:camera_inventory, :camera_stream]
        else
          [:inventory_enrichment, :console_access]
        end
    end
  end

  defp provider_scope_types(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile -> Enum.map(profile["scope_types"], &Map.fetch!(@scope_type_atoms, &1))
      nil -> @scope_types
    end
  end

  defp camera_provider?(provider), do: to_string(provider) in ["unifi-protect", "axis"]

  defp normalize_provider(value, integration_profiles) do
    value = value |> to_string() |> String.trim()
    allowed = @built_in_providers ++ Map.keys(integration_profiles)
    if value in allowed, do: value, else: "proxmox"
  end

  defp normalize_auth_method(provider, value, integration_profiles) do
    value = value |> to_string() |> String.trim()
    allowed = provider_auth_methods(provider, integration_profiles)
    Enum.find(allowed, &(to_string(&1) == value)) || hd(allowed)
  end

  defp normalize_form_purposes(provider, values, integration_profiles) do
    provider_purposes = provider_purposes(provider, integration_profiles)
    allowed = Enum.map(provider_purposes, &to_string/1)

    values
    |> normalize_purpose_values()
    |> Enum.filter(&(&1 in allowed))
    |> case do
      [] -> Enum.map(provider_purposes, &to_string/1)
      purposes -> purposes
    end
  end

  defp enum_param(params, key, allowed, label) do
    value = params |> Map.get(key, "") |> to_string()
    atom = Enum.find(allowed, &(to_string(&1) == value))
    if atom, do: {:ok, atom}, else: {:error, "Invalid #{label}"}
  end

  defp string_enum_param(params, key, allowed, label) do
    value = params |> Map.get(key, "") |> to_string() |> String.trim()
    if value in allowed, do: {:ok, value}, else: {:error, "Invalid #{label}"}
  end

  defp purposes_param(params, provider, integration_profiles) do
    allowed = provider_purposes(provider, integration_profiles)

    purposes =
      params
      |> Map.get("purposes", Map.get(params, "purpose", ""))
      |> normalize_purpose_values()
      |> Enum.map(fn value -> Enum.find(allowed, &(to_string(&1) == value)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if purposes == [], do: {:error, "Select at least one purpose"}, else: {:ok, purposes}
  end

  defp normalize_purpose_values(values) when is_list(values) do
    values
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_purpose_values(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp primary_purpose(purposes) do
    cond do
      :inventory_enrichment in purposes -> :inventory_enrichment
      :console_access in purposes -> :console_access
      true -> hd(purposes)
    end
  end

  defp integer_param(params, key, label) do
    case Integer.parse(to_string(Map.get(params, key, ""))) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "Invalid #{label}"}
    end
  end

  defp allowed_ports(value) do
    value = String.trim(to_string(value || ""))

    if value == "" do
      {:ok, []}
    else
      value
      |> String.split([",", " "], trim: true)
      |> Enum.reduce_while({:ok, []}, fn part, {:ok, ports} ->
        case Integer.parse(part) do
          {port, ""} when port > 0 and port <= 65_535 -> {:cont, {:ok, [port | ports]}}
          _ -> {:halt, {:error, "Allowed ports must be numbers from 1 to 65535"}}
        end
      end)
      |> case do
        {:ok, ports} -> {:ok, Enum.reverse(ports)}
        error -> error
      end
    end
  end

  defp ssh_host_key_policy_param(params, :ssh_private_key),
    do: enum_param(params, "ssh_host_key_policy", @ssh_host_key_policies, "SSH host key policy")

  defp ssh_host_key_policy_param(_params, _auth_method), do: {:ok, :known_hosts}

  defp validate_proxmox_transport("proxmox", :proxmox_api_token, tls_policy, _ssh_policy),
    do: require_proxmox_tls_verification(tls_policy)

  defp validate_proxmox_transport("proxmox", :ssh_private_key, _tls_policy, ssh_policy)
       when ssh_policy in [:known_hosts, :trust_on_first_use], do: :ok

  defp validate_proxmox_transport("proxmox", :ssh_private_key, _tls_policy, _ssh_policy),
    do: {:error, "Proxmox SSH access requires host key verification"}

  defp validate_proxmox_transport(_provider, _auth_method, _tls_policy, _ssh_policy), do: :ok

  defp require_proxmox_tls_verification(:verify), do: :ok

  defp require_proxmox_tls_verification(_tls_policy),
    do: {:error, "Proxmox API access requires TLS certificate verification"}

  defp credential_use_policy_param(params, purposes) do
    if :console_access in purposes do
      roles = credential_selector_values(params["credential_use_roles"])
      principals = credential_selector_values(params["credential_use_principals"])
      groups = credential_selector_values(params["credential_use_groups"])
      selectors = roles ++ principals ++ groups

      cond do
        selectors == [] ->
          {:error, "Console access requires at least one allowed role, user, or IdP group"}

        length(selectors) > 128 or Enum.any?(selectors, &(byte_size(&1) > 256)) ->
          {:error, "Console credential selectors exceed the supported size"}

        true ->
          policy =
            %{"schema" => CredentialUsePolicy.schema()}
            |> maybe_put_policy_selectors("roles", roles)
            |> maybe_put_policy_selectors("principals", principals)
            |> maybe_put_policy_selectors("groups", groups)

          {:ok, policy}
      end
    else
      {:ok, nil}
    end
  end

  defp credential_selector_values(value) when is_binary(value) do
    value
    |> String.split(~r/[,\r\n]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp credential_selector_values(values) when is_list(values),
    do: values |> Enum.flat_map(&credential_selector_values/1) |> Enum.uniq()

  defp credential_selector_values(_value), do: []

  defp maybe_put_policy_selectors(policy, _key, []), do: policy
  defp maybe_put_policy_selectors(policy, key, selectors), do: Map.put(policy, key, selectors)

  defp rule_metadata(params, provider, purposes, nil, credential_use_policy) do
    metadata =
      maybe_put_metadata_string(
        %{
          "purposes" => Enum.map(purposes, &Atom.to_string/1),
          "auto_discovery_enabled" =>
            to_string(provider) == "proxmox" and
              boolean_param(params, "auto_discovery_enabled")
        },
        "host",
        params["controller_host"],
        to_string(provider) == "unifi-protect"
      )

    {:ok, maybe_put_credential_use_policy(metadata, credential_use_policy)}
  end

  defp rule_metadata(params, _provider, purposes, profile, credential_use_policy) do
    schedule = profile["producer_schedule"]
    config = ConfigSchema.normalize_params(profile["config_schema"] || %{}, params["plugin_config"] || %{})

    with :ok <- ConfigSchema.validate_params(profile["config_schema"] || %{}, config),
         {:ok, cadence_seconds} <- strict_integer(params, "cadence_seconds"),
         true <-
           cadence_seconds >= schedule["min_cadence_seconds"] and
             cadence_seconds <= schedule["max_cadence_seconds"] do
      metadata =
        maybe_put_credential_use_policy(
          %{
            "plugin_integration" => true,
            "plugin_config" => config,
            "purposes" => Enum.map(purposes, &Atom.to_string/1),
            "schedule_enabled" => boolean_param(params, "schedule_enabled"),
            "cadence_seconds" => cadence_seconds
          },
          credential_use_policy
        )

      {:ok, metadata}
    else
      false ->
        {:error,
         "Cadence must be between #{schedule["min_cadence_seconds"]} and #{schedule["max_cadence_seconds"]} seconds"}

      {:error, errors} when is_list(errors) ->
        {:error, "Invalid plugin configuration: #{Enum.join(errors, "; ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_credential_use_policy(metadata, policy) when is_map(policy),
    do: Map.put(metadata, "credential_use_policy", policy)

  defp maybe_put_credential_use_policy(metadata, _policy), do: metadata

  defp strict_integer(params, key) do
    case Integer.parse(to_string(Map.get(params, key, ""))) do
      {value, ""} -> {:ok, value}
      _ -> {:error, "Invalid setting: #{key}"}
    end
  end

  defp validate_provider_scope(provider, scope, integration_profiles) do
    case Map.get(integration_profiles, provider) do
      %{} when scope == :agent -> :ok
      %{} -> {:error, "Scheduled plugin integrations require agent scope"}
      nil -> :ok
    end
  end

  defp maybe_put_metadata_string(metadata, key, value, true) do
    case blank_to_nil(value) do
      nil -> metadata
      value -> Map.put(metadata, key, value)
    end
  end

  defp maybe_put_metadata_string(metadata, _key, _value, _condition), do: metadata

  defp metadata_form_value(metadata, key, default) do
    metadata
    |> normalize_metadata()
    |> Map.get(key, default)
  end

  defp controller_host_from_metadata(metadata) do
    metadata = normalize_metadata(metadata)

    first_non_empty([
      Map.get(metadata, "host"),
      Map.get(metadata, "controller_host"),
      Map.get(metadata, "static_host")
    ]) || ""
  end

  defp credential_policy_selectors(metadata, key) do
    metadata
    |> normalize_metadata()
    |> Map.get("credential_use_policy", %{})
    |> normalize_metadata()
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp put_default_when_blank(params, key, default) do
    case blank_to_nil(Map.get(params, key)) do
      nil -> Map.put(params, key, default)
      _value -> params
    end
  end

  defp put_plugin_defaults(params, %{} = _profile, defaults) do
    normalized =
      params
      |> Map.put("scope_type", defaults["scope_type"])
      |> Map.put("target_query", "in:agents")
      |> Map.put("allowed_ports", "")
      |> Map.put("tls_policy", "verify")
      |> Map.put_new("plugin_config", defaults["plugin_config"] || %{})

    normalized
    |> put_default_when_blank("schedule_enabled", defaults["schedule_enabled"])
    |> put_default_when_blank("cadence_seconds", defaults["cadence_seconds"])
  end

  defp put_plugin_defaults(params, _profile, _defaults), do: params

  defp maybe_clear_camera_only_fields(params, provider)
       when provider in [:"unifi-protect", :axis, "unifi-protect", "axis"] do
    params
    |> Map.put("auto_discovery_enabled", "false")
    |> Map.put("ssh_host_key_policy", "known_hosts")
  end

  defp maybe_clear_camera_only_fields(params, _provider), do: params

  defp required_string(params, key) do
    case params |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, key
      value -> value
    end
  end

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp proxmox_token_identity(user, realm, token_id) do
    user = user |> to_string() |> String.trim() |> String.replace(~r/@.*/, "")
    realm = realm |> to_string() |> String.trim()
    token_id = token_id |> to_string() |> String.trim()

    if String.contains?(token_id, "!") do
      token_id
    else
      "#{user}@#{realm}!#{token_id}"
    end
  end

  defp secret_fingerprint(payload) do
    digest =
      :sha256
      |> :crypto.hash(payload)
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  defp boolean_param(params, key) do
    params
    |> Map.get(key, "false")
    |> case do
      value when value in [true, "true", "on", "1", 1] -> true
      _ -> false
    end
  end

  defp merge_rule_metadata(rule, attrs) do
    metadata =
      rule.metadata
      |> normalize_metadata()
      |> Map.drop(managed_rule_metadata_keys())
      |> Map.merge(Map.get(attrs, :metadata, %{}))

    Map.put(attrs, :metadata, metadata)
  end

  defp managed_rule_metadata_keys do
    [
      "purposes",
      "auto_discovery_enabled",
      "host",
      "controller_host",
      "static_host",
      "plugin_integration",
      "plugin_config",
      "schedule_enabled",
      "cadence_seconds",
      "credential_use_policy"
    ]
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp auto_discovery_enabled?(rule) do
    rule
    |> Map.get(:metadata, %{})
    |> normalize_metadata()
    |> Map.get("auto_discovery_enabled", false)
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_value), do: false

  defp credential_preview_resolver do
    Application.get_env(
      :serviceradar_web_ng,
      :network_credential_rule_preview_resolver,
      SRQLInputResolver
    )
  end

  defp enum_options(values), do: Enum.map(values, &{format_atom(&1), to_string(&1)})

  defp provider_options(integration_profiles) do
    built_in = [
      {"Proxmox VE", "proxmox"},
      {"UniFi Protect", "unifi-protect"},
      {"Axis (VAPIX)", "axis"}
    ]

    dynamic =
      integration_profiles
      |> integration_profile_list()
      |> Enum.map(&{&1["label"], &1["provider"]})

    built_in ++ dynamic
  end

  defp integration_profile_list(integration_profiles) do
    integration_profiles
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1["label"] || &1["provider"]))
  end

  defp plugin_integration_provider?(provider, integration_profiles),
    do: Map.has_key?(integration_profiles, to_string(provider))

  defp form_plugin_config(%Form{params: params}) when is_map(params) do
    case Map.get(params, "plugin_config") do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp form_plugin_config(_form), do: %{}

  defp secret_options_for(secrets, provider, auth_method, selected_secret_id) do
    secrets
    |> Enum.filter(fn secret ->
      secret_matches_rule?(secret, provider, auth_method) or
        to_string(secret.id) == to_string(selected_secret_id)
    end)
    |> Enum.map(&{secret_label(&1), &1.id})
  end

  defp secret_matches_rule?(secret, provider, auth_method) do
    to_string(secret.provider) == to_string(provider) and
      secret_kind_matches_auth?(secret.credential_kind, auth_method)
  end

  defp secret_kind_matches_auth?(:api_token, auth_method)
       when auth_method in [:proxmox_api_token, "proxmox_api_token", :api_key, "api_key"], do: true

  defp secret_kind_matches_auth?(:username_password, auth_method)
       when auth_method in [:username_password, "username_password"], do: true

  defp secret_kind_matches_auth?(:ssh_private_key, auth_method) when auth_method in [:ssh_private_key, "ssh_private_key"],
    do: true

  defp secret_kind_matches_auth?(_kind, _auth_method), do: false

  defp secret_label(secret) do
    [secret.provider, secret.name, format_atom(secret.credential_kind)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.credentials.manage")

  # The credential test dispatcher currently only supports Proxmox API-token
  # rules (`NetworkCredentialRuleTestPlan.ensure_proxmox_api_rule/1`); other
  # providers need an agent-side test command before the action can be wired.
  defp testable_rule?(rule) do
    rule.provider == "proxmox" and rule.auth_method == :proxmox_api_token
  end

  defp format_scope(rule), do: "#{format_atom(rule.scope_type)}: #{rule.scope_value}"

  defp format_purposes(rule) do
    rule
    |> rule_purposes()
    |> Enum.map_join(", ", &String.replace(&1, "_", " "))
  end

  defp rule_purposes(rule) do
    metadata =
      rule
      |> Map.get(:metadata, %{})
      |> normalize_metadata()

    metadata
    |> Map.get("purposes", [to_string(rule.purpose)])
    |> normalize_purpose_values()
    |> case do
      [] -> implicit_rule_purposes(rule)
      [purpose] -> implicit_rule_purposes(rule, purpose)
      purposes -> purposes
    end
  end

  defp implicit_rule_purposes(%{auth_method: :proxmox_api_token}, "inventory_enrichment"),
    do: ["inventory_enrichment", "console_access"]

  defp implicit_rule_purposes(_rule, purpose), do: [purpose]

  defp implicit_rule_purposes(rule), do: implicit_rule_purposes(rule, to_string(rule.purpose))

  defp agent_options(agents) when is_list(agents) do
    Enum.map(agents, fn agent ->
      {agent_option_label(agent), agent.uid}
    end)
  end

  defp agent_options(_agents), do: []

  defp agent_option_label(%Agent{} = agent) do
    status =
      agent.status
      |> format_atom()
      |> case do
        "" -> "Unknown"
        value -> value
      end

    host = first_non_empty([agent.host, agent.name, agent.ip])

    [agent.uid, host, status]
    |> Enum.reject(&empty_label_part?/1)
    |> Enum.join(" - ")
  end

  defp empty_label_part?(nil), do: true
  defp empty_label_part?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_label_part?(_value), do: false

  defp form_string(form, field) do
    form
    |> Form.input_value(field)
    |> to_string()
  end

  defp form_purposes(form) do
    form
    |> Form.input_value(:purposes)
    |> normalize_purpose_values()
  end

  defp device_label(device) when is_map(device) do
    first_non_empty([
      Map.get(device, "hostname"),
      Map.get(device, "name"),
      Map.get(device, "uid"),
      Map.get(device, "device_uid"),
      Map.get(device, "id")
    ])
  end

  defp device_address(device) when is_map(device) do
    first_non_empty([
      Map.get(device, "ip"),
      Map.get(device, "device_ip"),
      Map.get(device, "management_ip"),
      "-"
    ])
  end

  defp device_agent(device) when is_map(device) do
    first_non_empty([Map.get(device, "agent_id"), Map.get(device, "agent_uid"), "-"])
  end

  defp first_non_empty(values) when is_list(values) do
    Enum.find_value(values, "-", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when not is_nil(value) ->
        to_string(value)

      _ ->
        nil
    end)
  end

  defp encode_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true)
    end
  end

  defp format_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_timestamp(_timestamp), do: "never"

  defp format_last_test(%{last_test_status: nil}), do: "Not tested"

  defp format_last_test(rule) do
    [format_atom(rule.last_test_status), rule.last_test_message]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
  end

  defp runtime_label(rule, profiles, schedules) do
    if plugin_integration_provider?(rule.provider, profiles) do
      case Map.get(schedules, to_string(rule.id)) do
        %{enabled: true} -> "Scheduled"
        %{} -> "On demand"
        nil -> "Pending"
      end
    else
      if auto_discovery_enabled?(rule), do: "Auto", else: "SRQL"
    end
  end

  defp runtime_badge_class(rule, profiles, schedules) do
    if plugin_integration_provider?(rule.provider, profiles) do
      case Map.get(schedules, to_string(rule.id)) do
        %{enabled: true} -> "badge-success"
        %{} -> "badge-info"
        nil -> "badge-warning"
      end
    else
      if auto_discovery_enabled?(rule), do: "badge-warning", else: "badge-ghost"
    end
  end

  defp runtime_status(rule, profiles, schedules) do
    if plugin_integration_provider?(rule.provider, profiles) do
      case Map.get(schedules, to_string(rule.id)) do
        %{last_status: status, last_run_at: last_run_at} ->
          "#{status} / #{format_timestamp(last_run_at)}"

        nil ->
          "Awaiting provisioning"
      end
    else
      format_last_test(rule)
    end
  end

  defp format_atom(nil), do: nil

  defp format_atom(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_atom(value), do: to_string(value)

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)
  defp format_error({field, reason}), do: "#{field}: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")
  defp format_error(reason), do: inspect(reason)
end
