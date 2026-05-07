defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive do
  @moduledoc """
  Network credential rules settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @current_path "/settings/networks/credentials"
  @auth_methods ~w(proxmox_api_token ssh_private_key username_password certificate opaque)a
  @purposes ~w(inventory_enrichment console_access discovery generic)a
  @scope_types ~w(agent gateway partition)a
  @tls_policies ~w(verify skip_verify)a
  @ssh_host_key_policies ~w(known_hosts trust_on_first_use skip_verify)a

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
       |> assign(:loading?, true)
       |> assign(:form_mode, nil)
       |> assign(:editing_rule, nil)
       |> assign(:rule_preview, nil)
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
    case normalize_rule_params(params) do
      {:ok, attrs} ->
        save_rule(socket, attrs)

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:rule_form, rule_form(params))
         |> put_flash(:error, message)}
    end
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
      {:noreply, assign(socket, :rule_preview, %{rule: rule, preview: preview})}
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

  def handle_event("new_proxmox_secret", _params, socket) do
    {:noreply, assign(socket, :secret_form, secret_form(default_secret_params()))}
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
      |> assign(:auth_methods, @auth_methods)
      |> assign(:purposes, @purposes)
      |> assign(:scope_types, @scope_types)
      |> assign(:tls_policies, @tls_policies)
      |> assign(:ssh_host_key_policies, @ssh_host_key_policies)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <div class="space-y-4">
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.network_nav current_path={@current_path} current_scope={@current_scope} />
        </div>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <h1 class="text-xl font-semibold">Credential Rules</h1>
            <div class="flex flex-wrap gap-2">
              <button type="button" class="btn btn-ghost btn-sm" phx-click="new_proxmox_secret">
                New Proxmox Token
              </button>
              <.link navigate={~p"/settings/networks/credentials/new"} class="btn btn-primary btn-sm">
                New Rule
              </.link>
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
                    <th>Discovery</th>
                    <th>Secret</th>
                    <th>Priority</th>
                    <th>Status</th>
                    <th>Last Test</th>
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
                  <tr :for={rule <- @rules}>
                    <td class="font-medium">{rule.name}</td>
                    <td>{rule.provider}</td>
                    <td>{format_atom(rule.purpose)}</td>
                    <td>{format_scope(rule)}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        if(auto_discovery_enabled?(rule), do: "badge-warning", else: "badge-ghost")
                      ]}>
                        {if auto_discovery_enabled?(rule), do: "Auto", else: "SRQL"}
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
                    <td>{format_last_test(rule)}</td>
                    <td>
                      <div class="flex justify-end gap-2">
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="test_rule"
                          phx-value-id={rule.id}
                        >
                          Test
                        </button>
                        <button
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="preview_rule"
                          phx-value-id={rule.id}
                        >
                          Preview
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
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <.rule_form_modal
          :if={@form_mode in [:new, :edit]}
          form={@rule_form}
          mode={@form_mode}
          secret_options={@secret_options}
          auth_methods={@auth_methods}
          purposes={@purposes}
          scope_types={@scope_types}
          tls_policies={@tls_policies}
          ssh_host_key_policies={@ssh_host_key_policies}
        />

        <.rule_preview_modal :if={@rule_preview} rule_preview={@rule_preview} />
        <.secret_form_modal :if={@secret_form} form={@secret_form} tls_policies={@tls_policies} />
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :tls_policies, :list, required: true

  defp secret_form_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-3xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">New Proxmox Token</h2>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_secret_form">
            Close
          </button>
        </div>

        <.form for={@form} phx-submit="save_secret" class="space-y-4">
          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@form[:name]} label="Name" required />
            <.input field={@form[:user]} label="User" required />
            <.input field={@form[:realm]} label="Realm" required />
            <.input field={@form[:token_id]} label="Token ID" required />
            <.input
              field={@form[:tls_policy]}
              type="select"
              label="TLS Policy"
              options={enum_options(@tls_policies)}
              required
            />
          </div>

          <.input field={@form[:token_secret]} type="password" label="Token Secret" required />
          <.input field={@form[:description]} type="textarea" label="Description" />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_secret_form">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              Save Token
            </button>
          </div>
        </.form>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_secret_form">Close</button>
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
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_preview">Close</button>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :mode, :atom, required: true
  attr :secret_options, :list, required: true
  attr :auth_methods, :list, required: true
  attr :purposes, :list, required: true
  attr :scope_types, :list, required: true
  attr :tls_policies, :list, required: true
  attr :ssh_host_key_policies, :list, required: true

  defp rule_form_modal(assigns) do
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

        <.form for={@form} phx-submit="save_rule" class="space-y-4">
          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@form[:name]} label="Name" required />
            <.input field={@form[:provider]} label="Provider" required />
            <.input field={@form[:priority]} type="number" label="Priority" min="0" required />
            <.input
              field={@form[:secret_id]}
              type="select"
              label="Secret"
              options={@secret_options}
              prompt="Select a secret"
              required
            />
            <.input
              field={@form[:auth_method]}
              type="select"
              label="Auth Method"
              options={enum_options(@auth_methods)}
              required
            />
            <.input
              field={@form[:purpose]}
              type="select"
              label="Purpose"
              options={enum_options(@purposes)}
              required
            />
            <.input
              field={@form[:scope_type]}
              type="select"
              label="Scope Type"
              options={enum_options(@scope_types)}
              required
            />
            <.input field={@form[:scope_value]} label="Scope Value" required />
            <.input
              field={@form[:tls_policy]}
              type="select"
              label="TLS Policy"
              options={enum_options(@tls_policies)}
              required
            />
            <.input
              field={@form[:ssh_host_key_policy]}
              type="select"
              label="SSH Host Key Policy"
              options={enum_options(@ssh_host_key_policies)}
              required
            />
          </div>

          <.input field={@form[:target_query]} type="textarea" label="Target Query" required />
          <.input
            field={@form[:auto_discovery_enabled]}
            type="checkbox"
            label="Allow auto-discovery credential trials"
          />
          <.input field={@form[:allowed_ports]} label="Allowed Ports" />
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
    scope = socket.assigns.current_scope
    {rules, secrets} = {load_rules(scope), load_secrets(scope)}
    secret_names = Map.new(secrets, &{&1.id, secret_label(&1)})

    socket =
      socket
      |> assign(:rules, rules)
      |> assign(:secrets, secrets)
      |> assign(:secret_options, Enum.map(secrets, &{secret_label(&1), &1.id}))
      |> assign(:secret_names, secret_names)
      |> assign(:loading?, false)

    case socket.assigns.form_mode do
      :new ->
        assign(socket, :rule_form, rule_form(default_rule_params()))

      :edit ->
        assign_edit_form(socket, params["id"], rules)

      _ ->
        socket
        |> assign(:editing_rule, nil)
        |> assign(:rule_form, rule_form(default_rule_params()))
    end
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
      {:ok, _secret} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proxmox token saved")
         |> assign(:secret_form, nil)
         |> load_page(%{})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save token: #{format_error(reason)}")}
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

  defp normalize_rule_params(params) do
    with {:ok, auth_method} <- enum_param(params, "auth_method", @auth_methods, "auth method"),
         {:ok, purpose} <- enum_param(params, "purpose", @purposes, "purpose"),
         {:ok, scope_type} <- enum_param(params, "scope_type", @scope_types, "scope type"),
         {:ok, tls_policy} <- enum_param(params, "tls_policy", @tls_policies, "TLS policy"),
         {:ok, ssh_policy} <-
           enum_param(params, "ssh_host_key_policy", @ssh_host_key_policies, "SSH host key policy"),
         {:ok, priority} <- integer_param(params, "priority", "priority"),
         {:ok, allowed_ports} <- allowed_ports(params["allowed_ports"]) do
      {:ok,
       %{
         name: required_string(params, "name"),
         description: blank_to_nil(params["description"]),
         provider: required_string(params, "provider"),
         auth_method: auth_method,
         purpose: purpose,
         target_query: required_string(params, "target_query"),
         scope_type: scope_type,
         scope_value: required_string(params, "scope_value"),
         secret_id: required_string(params, "secret_id"),
         priority: priority,
         allowed_ports: allowed_ports,
         tls_policy: tls_policy,
         ssh_host_key_policy: ssh_policy,
         metadata: %{
           "auto_discovery_enabled" => boolean_param(params, "auto_discovery_enabled")
         }
       }}
    end
  rescue
    ArgumentError -> {:error, "Required fields are missing"}
  end

  defp normalize_secret_params(params) do
    with {:ok, tls_policy} <- enum_param(params, "tls_policy", @tls_policies, "TLS policy") do
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

  defp default_rule_params do
    %{
      "name" => "",
      "description" => "",
      "provider" => "proxmox",
      "auth_method" => "proxmox_api_token",
      "purpose" => "inventory_enrichment",
      "target_query" => "in:devices protocol:proxmox-api",
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "8006",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "auto_discovery_enabled" => "false"
    }
  end

  defp default_secret_params do
    %{
      "name" => "",
      "description" => "",
      "user" => "root",
      "realm" => "pam",
      "token_id" => "",
      "tls_policy" => "verify",
      "token_secret" => ""
    }
  end

  defp rule_params(rule) do
    %{
      "name" => rule.name,
      "description" => rule.description || "",
      "provider" => rule.provider,
      "auth_method" => to_string(rule.auth_method),
      "purpose" => to_string(rule.purpose),
      "target_query" => rule.target_query,
      "scope_type" => to_string(rule.scope_type),
      "scope_value" => rule.scope_value,
      "secret_id" => to_string(rule.secret_id),
      "priority" => to_string(rule.priority),
      "allowed_ports" => Enum.join(rule.allowed_ports || [], ", "),
      "tls_policy" => to_string(rule.tls_policy),
      "ssh_host_key_policy" => to_string(rule.ssh_host_key_policy),
      "auto_discovery_enabled" => auto_discovery_enabled?(rule)
    }
  end

  defp rule_form(params), do: to_form(params, as: :credential_rule)

  defp secret_form(params), do: to_form(params, as: :credential_secret)

  defp enum_param(params, key, allowed, label) do
    value = params |> Map.get(key, "") |> to_string()
    atom = Enum.find(allowed, &(to_string(&1) == value))
    if atom, do: {:ok, atom}, else: {:error, "Invalid #{label}"}
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

    "#{user}@#{realm}!#{token_id}"
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
      |> Map.merge(Map.get(attrs, :metadata, %{}))

    Map.put(attrs, :metadata, metadata)
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

  defp secret_label(secret) do
    [secret.provider, secret.name, format_atom(secret.credential_kind)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.credentials.manage")

  defp format_scope(rule), do: "#{format_atom(rule.scope_type)}: #{rule.scope_value}"

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

  defp format_last_test(%{last_test_status: nil}), do: "Not tested"

  defp format_last_test(rule) do
    [format_atom(rule.last_test_status), rule.last_test_message]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
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
