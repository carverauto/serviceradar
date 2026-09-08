defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive do
  @moduledoc """
  Network credential rules settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias Phoenix.HTML.Form
  alias ServiceRadar.Credentials.CredentialRuleConsumers
  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialRulePreview
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.SRQLInputResolver
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.PluginConfigForm
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialInventoryComponents
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialManagement
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @current_path "/settings/networks/credentials"
  @tls_policies ~w(verify skip_verify)a

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "Credentials and Rules")
       |> assign(:current_path, @current_path)
       |> assign(:rules, [])
       |> assign(:secrets, [])
       |> assign(:focused_credential_id, nil)
       |> assign(:credential_usage_by_id, %{})
       |> assign(:credential_modal, nil)
       |> assign(:credential_form, nil)
       |> assign(:credential_descriptor, nil)
       |> assign(:credential_modal_usage, :unavailable)
       |> assign(:credential_action_error, nil)
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
       |> assign(:secret_descriptor, nil)
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

  def handle_event("new_rule_secret", _params, socket) do
    provider = form_string(socket.assigns.rule_form, :provider)
    auth_method = form_string(socket.assigns.rule_form, :auth_method)

    case credential_method(socket.assigns.integration_profiles, provider, auth_method) do
      nil ->
        {:noreply, put_flash(socket, :error, "Credential descriptor is no longer available")}

      descriptor ->
        {:noreply, open_descriptor_secret_form(socket, descriptor)}
    end
  end

  def handle_event("new_descriptor_secret", %{"provider" => provider, "method" => method}, socket) do
    case credential_method(socket.assigns.integration_profiles, provider, method) do
      nil ->
        {:noreply, put_flash(socket, :error, "Credential descriptor is no longer available")}

      descriptor ->
        {:noreply, open_descriptor_secret_form(socket, descriptor)}
    end
  end

  def handle_event("close_secret_form", _params, socket) do
    {:noreply, socket |> assign(:secret_form, nil) |> assign(:secret_descriptor, nil)}
  end

  def handle_event("save_secret", %{"credential_secret" => params}, socket) do
    case normalize_secret_params(params, socket.assigns.integration_profiles) do
      {:ok, attrs} ->
        save_secret(socket, attrs)

      {:error, message} ->
        params = sanitize_secret_form_params(params, socket.assigns.secret_descriptor)

        {:noreply,
         socket
         |> assign(:secret_form, secret_form(params))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("edit_credential", %{"id" => id}, socket) do
    open_credential_modal(socket, :edit, id)
  end

  def handle_event("rotate_credential", %{"id" => id}, socket) do
    open_credential_modal(socket, :rotate, id)
  end

  def handle_event("delete_credential", %{"id" => id}, socket) do
    open_credential_modal(socket, :delete, id)
  end

  def handle_event("close_credential_modal", _params, socket) do
    {:noreply, clear_credential_modal(socket)}
  end

  def handle_event("save_credential_details", %{"credential_details" => params}, socket) do
    id = Map.get(params, "id", "")

    case CredentialManagement.edit_details(socket.assigns.current_scope, id, params) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:info, "Credential details saved")
         |> reload_page_data()}

      {:error, :not_authorized} ->
        {:noreply, credential_action_unauthorized(socket)}

      {:error, :credential_not_found} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:error, "Credential not found")
         |> reload_page_data()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(
           :credential_form,
           credential_details_form(%{
             "id" => id,
             "name" => Map.get(params, "name", ""),
             "description" => Map.get(params, "description", "")
           })
         )
         |> assign(:credential_action_error, "Credential details could not be saved")}
    end
  end

  def handle_event("save_credential_rotation", %{"credential_rotation" => params}, socket) do
    id = if is_binary(params["id"]), do: params["id"], else: ""
    save_credential_rotation(socket, id, Map.get(params, "fields", %{}))
  end

  def handle_event("confirm_delete_credential", %{"credential_delete" => params}, socket) do
    id = Map.get(params, "id", "")
    confirmation_id = Map.get(params, "confirmation_id", "")

    case CredentialManagement.delete(
           socket.assigns.current_scope,
           id,
           confirmation_id
         ) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:info, "Credential permanently deleted")
         |> push_patch(to: ~p"/settings/networks/credentials")}

      {:error, :not_authorized} ->
        {:noreply, credential_action_unauthorized(socket)}

      {:error, :credential_not_found} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:error, "Credential not found")
         |> reload_page_data()}

      {:error, :credential_confirmation_mismatch} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_delete_form(id))
         |> assign(:credential_action_error, "Type the exact credential ID to confirm deletion")}

      {:error, :credential_in_use, context} ->
        {:noreply, show_delete_block(socket, context, "Credential is still in use")}

      {:error, :credential_usage_unavailable, context} ->
        {:noreply,
         show_delete_block(
           socket,
           context,
           "Usage is unavailable; the credential was not deleted"
         )}

      {:error, :credential_in_use} ->
        reopen_delete_after_race(socket, id)

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_delete_form(id))
         |> assign(:credential_action_error, "Credential could not be deleted")}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:provider_options, provider_options(assigns.integration_profiles))
      |> assign(:integration_profile_list, rule_profile_list(assigns.integration_profiles))
      |> assign(:credential_method_list, credential_method_list(assigns.integration_profiles))

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
              <h1 class="text-xl font-semibold">Credentials and Rules</h1>
              <p class="mt-1 text-sm text-sr-muted">
                Reusable credentials hold encrypted authentication material. Credential rules
                decide where that material may be applied. Profiles such as SNMP can reference a
                reusable credential directly, so a credential may be in use even when it has no
                credential rule.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.ui_dropdown align="end" menu_class="w-60 max-w-60">
                <:trigger>
                  <.ui_button type="button" size="sm" variant="ghost">New Credential</.ui_button>
                </:trigger>
                <:item :for={descriptor <- @credential_method_list}>
                  <button
                    type="button"
                    phx-click="new_descriptor_secret"
                    phx-value-provider={descriptor.provider}
                    phx-value-method={descriptor.method["id"]}
                  >
                    {descriptor.profile["label"]} · {descriptor.method["label"]}
                  </button>
                </:item>
                <:item :if={@credential_method_list == []}>
                  <span class="px-2 py-1 text-sm text-sr-muted">
                    Import and approve an integration package first
                  </span>
                </:item>
              </.ui_dropdown>
              <.ui_dropdown align="end" menu_class="w-60 max-w-60">
                <:trigger>
                  <.ui_button type="button" size="sm" variant="primary">New Rule</.ui_button>
                </:trigger>
                <:item :for={profile <- @integration_profile_list}>
                  <.link navigate={
                    ~p"/settings/networks/credentials/new?provider=#{profile["provider"]}"
                  }>
                    {profile["label"]}
                  </.link>
                </:item>
                <:item :if={@integration_profile_list == []}>
                  <span class="px-2 py-1 text-sm text-sr-muted">
                    No approved integration descriptors
                  </span>
                </:item>
              </.ui_dropdown>
            </div>
          </div>

          <CredentialInventoryComponents.credential_inventory_table
            loading?={@loading?}
            secrets={@secrets}
            focused_credential_id={@focused_credential_id}
            integration_profiles={@integration_profiles}
            usage_by_id={@credential_usage_by_id}
          />

          <div id="credential-rules" class="space-y-1 pt-2 scroll-mt-24">
            <h2 class="text-base font-semibold">Credential Rules</h2>
            <p class="text-sm text-sr-muted">
              Scoped rules bind a reusable credential to eligible targets and consumers.
            </p>
          </div>

          <div class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
            <div class="sr-ui-table-shell">
              <table class={ui_table_class(size: "sm")}>
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
                    <td colspan="10" class="py-8 text-center text-sm text-sr-muted">
                      Loading credential rules.
                    </td>
                  </tr>
                  <tr :if={!@loading? and @rules == []}>
                    <td colspan="10" class="py-8 text-center text-sm text-sr-muted">
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
                          "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold",
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
                      <td>
                        <.runtime_status
                          rule={rule}
                          profiles={@integration_profiles}
                          schedules={@integration_schedules}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                        />
                      </td>
                      <td>
                        <div class="flex justify-end gap-2">
                          <.ui_button
                            :if={
                              scheduled_integration_provider?(rule.provider, @integration_profiles)
                            }
                            type="button"
                            size="xs"
                            variant="ghost"
                            phx-click="run_integration_now"
                            phx-value-id={rule.id}
                            disabled={!Map.has_key?(@integration_schedules, to_string(rule.id))}
                          >
                            Run Now
                          </.ui_button>
                          <.ui_button
                            :if={
                              !scheduled_integration_provider?(rule.provider, @integration_profiles)
                            }
                            type="button"
                            size="xs"
                            variant="ghost"
                            phx-click="preview_rule"
                            phx-value-id={rule.id}
                          >
                            Preview
                          </.ui_button>
                          <.ui_button
                            type="button"
                            size="xs"
                            variant="ghost"
                            phx-click="toggle_consumers"
                            phx-value-id={rule.id}
                          >
                            Consumers
                          </.ui_button>
                          <.ui_button
                            navigate={~p"/settings/networks/credentials/#{rule.id}/edit"}
                            size="xs"
                            variant="ghost"
                          >
                            Edit
                          </.ui_button>
                          <.ui_button
                            :if={rule.enabled}
                            type="button"
                            size="xs"
                            variant="ghost"
                            phx-click="disable_rule"
                            phx-value-id={rule.id}
                          >
                            Disable
                          </.ui_button>
                          <.ui_button
                            :if={!rule.enabled}
                            type="button"
                            size="xs"
                            variant="ghost"
                            phx-click="enable_rule"
                            phx-value-id={rule.id}
                          >
                            Enable
                          </.ui_button>
                        </div>
                      </td>
                    </tr>
                    <tr :if={@expanded_rule_id == to_string(rule.id)} class="bg-sr-subtle/40">
                      <td colspan="10">
                        <.rule_consumers_panel
                          consumers={@rule_consumers}
                          rule_id={rule.id}
                          timezone={@current_scope.user.timezone || "Etc/UTC"}
                        />
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
          agent_options={@agent_options}
          editing_rule={@editing_rule}
        />

        <.rule_preview_modal :if={@rule_preview} rule_preview={@rule_preview} />
        <.secret_form_modal
          :if={@secret_form}
          form={@secret_form}
          descriptor={@secret_descriptor}
        />
        <CredentialInventoryComponents.credential_action_modal
          :if={@credential_modal}
          modal={@credential_modal}
          form={@credential_form}
          descriptor={@credential_descriptor}
          usage={@credential_modal_usage}
          error={@credential_action_error}
        />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :descriptor, :map, default: nil

  defp secret_form_modal(assigns) do
    assigns =
      assigns
      |> assign(:secret_kind, form_string(assigns.form, :kind))
      |> assign(
        :secret_title,
        descriptor_secret_title(assigns.descriptor) ||
          secret_form_title(form_string(assigns.form, :kind))
      )

    ~H"""
    <dialog
      id="network-credential-secret-form-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-lg rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">{@secret_title}</h2>
          <.ui_button type="button" phx-click="close_secret_form" size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>

        <.form for={@form} phx-submit="save_secret" class="space-y-4">
          <input type="hidden" name={@form[:kind].name} value={@secret_kind} />

          <div :if={@secret_kind == "descriptor" and @descriptor} class="space-y-4">
            <input
              type="hidden"
              name="credential_secret[provider]"
              value={@descriptor.provider}
            />
            <input
              type="hidden"
              name="credential_secret[auth_method]"
              value={@descriptor.method["id"]}
            />

            <p :if={@descriptor.method["description"]} class="text-sm text-sr-muted">
              {@descriptor.method["description"]}
            </p>

            <div class="grid gap-4 md:grid-cols-2">
              <.input field={@form[:name]} label="Name" required />
              <.input
                :for={field <- @descriptor.method["fields"]}
                id={"credential_secret_fields_#{field["id"]}"}
                name={"credential_secret[fields][#{field["id"]}]"}
                value={descriptor_field_value(@form, field)}
                type={descriptor_field_input_type(field)}
                label={field["label"]}
                placeholder={field["placeholder"]}
                minlength={field["min_length"]}
                maxlength={field["max_length"]}
                required={field["required"]}
                autocomplete={if(field["secret"], do: "new-password", else: "off")}
              />
            </div>

            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>

          <div class="sr-ui-modal-action">
            <.ui_button type="button" phx-click="close_secret_form" size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
          </div>
        </.form>
      </div>
    </dialog>
    """
  end

  attr :consumers, :map, default: nil
  attr :rule_id, :any, required: true
  attr :timezone, :string, required: true

  defp rule_consumers_panel(assigns) do
    ~H"""
    <div class="space-y-2 p-2 text-xs">
      <%= cond do %>
        <% is_nil(@consumers) -> %>
          <p class="text-sr-muted">Loading consumers.</p>
        <% @consumers.total == 0 -> %>
          <p class="text-sr-muted">
            No materialized plugin assignments yet — the reconciler has not produced assignments
            for this rule. Check that the rule is enabled and that its scope, purposes, and
            target query match connected agents.
          </p>
        <% true -> %>
          <p class="text-sr-muted">
            Materializes {@consumers.total} assignment(s)
            ({@consumers.enabled_count} enabled) across {length(@consumers.agent_uids)} agent(s).
            Last materialized
            <.user_time
              id={"settings-network-credential-rule-#{@rule_id}-last-materialized-at"}
              value={@consumers.last_materialized_at}
              timezone={@timezone}
              style={:compact}
              fallback="never"
            />.
          </p>
          <div class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
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
                  <td>
                    <.user_time
                      id={
                        "settings-network-credential-rule-#{dom_id_segment(@rule_id)}-consumer-#{dom_id_segment(consumer.agent_uid)}-#{dom_id_segment(consumer.plugin_id)}-#{dom_id_segment(consumer.purpose)}-last-materialized-at"
                      }
                      value={consumer.last_materialized_at}
                      timezone={@timezone}
                      style={:compact}
                      fallback="never"
                    />
                  </td>
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
    <dialog
      id="network-credential-rule-preview-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">Target Preview</h2>
          <.ui_button type="button" phx-click="close_preview" size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>

        <div class="space-y-4">
          <div class="grid gap-3 md:grid-cols-4">
            <div class="rounded-lg border border-sr-line p-3">
              <div class="text-xs text-sr-muted">Matched</div>
              <div class="text-xl font-semibold">{@rule_preview.preview.matched_devices}</div>
            </div>
            <div class="rounded-lg border border-sr-line p-3">
              <div class="text-xs text-sr-muted">In Scope</div>
              <div class="text-xl font-semibold">{@rule_preview.preview.scoped_devices}</div>
            </div>
            <div class="rounded-lg border border-sr-line p-3">
              <div class="text-xs text-sr-muted">Agents</div>
              <div class="text-xl font-semibold">{length(@rule_preview.preview.agents)}</div>
            </div>
            <div class="rounded-lg border border-sr-line p-3">
              <div class="text-xs text-sr-muted">Conflicts</div>
              <div class="text-xl font-semibold">{length(@rule_preview.preview.conflicts)}</div>
            </div>
          </div>

          <div class="grid gap-4 lg:grid-cols-2">
            <section class="space-y-2">
              <h3 class="text-sm font-semibold">Agent Distribution</h3>
              <div class="overflow-hidden rounded-lg border border-sr-line">
                <table class={ui_table_class(size: "sm")}>
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th class="text-right">Devices</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@rule_preview.preview.agents == []}>
                      <td colspan="2" class="py-4 text-center text-sm text-sr-muted">
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
              <div class="overflow-hidden rounded-lg border border-sr-line">
                <table class={ui_table_class(size: "sm")}>
                  <thead>
                    <tr>
                      <th>Device</th>
                      <th>Address</th>
                      <th>Agent</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@rule_preview.preview.sample_devices == []}>
                      <td colspan="3" class="py-4 text-center text-sm text-sr-muted">
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
              <table class={ui_table_class(size: "sm")}>
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
                <p class="text-xs text-sr-muted">
                  {effective.targets.total} target(s) resolved from the rule's SRQL query
                  <span :if={effective.targets.truncated?}>
                    (showing first {length(effective.targets.sample)})
                  </span>
                  — secret references shown as-is; secret material is never resolved or displayed.
                </p>
                <div
                  :for={entry <- effective.purposes}
                  class="rounded-lg border border-sr-line p-3 space-y-2"
                >
                  <div class="flex flex-wrap items-center gap-2 text-xs">
                    <span class="badge badge-ghost badge-sm">{entry.purpose}</span>
                    <span class="font-mono">{entry.plugin_id}</span>
                    <span class="font-mono text-sr-muted">{entry.policy_id}</span>
                    <span :if={!entry.package_found?} class="badge badge-warning badge-sm">
                      no approved package
                    </span>
                    <span class="text-sr-muted">
                      every {entry.interval_seconds}s, timeout {entry.timeout_seconds}s
                    </span>
                  </div>
                  <pre class="max-h-64 overflow-auto rounded bg-sr-subtle/60 p-2 text-[11px] font-mono"><%= encode_json(entry.params_template) %></pre>
                </div>
                <div
                  :if={effective.targets.sample != []}
                  class="overflow-hidden rounded-lg border border-sr-line"
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
                <p class="text-xs text-sr-muted">Dry run unavailable.</p>
            <% end %>
          </section>
        </div>
      </div>
    </dialog>
    """
  end

  attr :form, :map, required: true
  attr :mode, :atom, required: true
  attr :secrets, :list, required: true
  attr :provider_options, :list, required: true
  attr :integration_profiles, :map, required: true
  attr :agent_options, :list, required: true
  attr :editing_rule, :any, default: nil

  defp rule_form_modal(assigns) do
    assigns =
      assigns
      |> assign(:scope_type_value, form_string(assigns.form, :scope_type))
      |> assign(:provider_value, form_string(assigns.form, :provider))
      |> assign(:auth_method_value, form_string(assigns.form, :auth_method))

    integration_profile = Map.get(assigns.integration_profiles, assigns.provider_value)
    auth_descriptor = credential_method_descriptor(integration_profile, assigns.auth_method_value)
    rule_controls = profile_rule_controls(integration_profile)
    tls_policies = effective_tls_policies(auth_descriptor)
    ssh_host_key_policies = descriptor_values(auth_descriptor, "ssh_host_key_policies")

    assigns =
      assigns
      |> assign(:integration_profile, integration_profile)
      |> assign(:plugin_integration?, scheduled_integration_profile?(integration_profile))
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
      |> assign(:show_ssh_policy?, ssh_host_key_policies != [])
      |> assign(:show_auto_discovery?, Map.get(rule_controls, "auto_discovery_enabled", false))
      |> assign(:show_controller_host?, Map.get(rule_controls, "controller_host", false))
      |> assign(:controller_host_label, controller_host_label(integration_profile))
      |> assign(:show_allowed_ports?, Map.get(rule_controls, "allowed_ports", false))
      |> assign(:show_target_query?, Map.get(rule_controls, "target_query", false))
      |> assign(
        :show_tls_policy?,
        Map.get(rule_controls, "transport", false) and ssh_host_key_policies == []
      )
      |> assign(:provider_tls_policies, tls_policies)
      |> assign(:provider_ssh_host_key_policies, ssh_host_key_policies)
      |> assign(
        :secret_options_for_rule,
        secret_options_for(
          assigns.secrets,
          assigns.provider_value,
          assigns.auth_method_value,
          form_string(assigns.form, :secret_id),
          assigns.integration_profiles
        )
      )

    ~H"""
    <dialog
      id="network-credential-rule-form-modal"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">
            {if @mode == :new, do: "New Credential Rule", else: "Edit Credential Rule"}
          </h2>
          <.ui_button navigate={~p"/settings/networks/credentials"} size="sm" variant="ghost">
            Close
          </.ui_button>
        </div>

        <.form
          for={@form}
          id="credential-rule-form"
          phx-change="change_rule"
          phx-submit="save_rule"
          class="space-y-4"
        >
          <div
            :if={@integration_profile}
            class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-sr-ink/90"
          >
            {@integration_profile["description"] || @integration_profile["label"]} Credentials are
            resolved by the trusted host and delivered only through scoped runtime grants.
          </div>
          <div
            :if={@plugin_integration?}
            class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-sr-ink/90 space-y-2"
          >
            <p class="font-medium">Do not assign this plugin from Admin → Plugin Packages.</p>
            <p>
              Pick the agent in <span class="font-medium">Scope Value</span> below. Saving this
              rule creates the assignment and the inventory schedule. Put the service-account
              username and password in a credential on this page, not in package approval and
              not on Assign to Agent.
            </p>
          </div>
          <div
            :if={@provider_value == "unifi-protect"}
            class="rounded-lg border border-info/20 bg-info/10 p-3 text-sm text-sr-ink/90 space-y-2"
          >
            <p>
              Do not put the Protect password on the plugin assignment form. Create an API key
              secret (preferred) or a local-account secret, then this rule materializes it into
              the UniFi Protect camera plugins.
            </p>
            <p>
              The plugin talks to UniFi OS, not each camera: login at <span class="font-mono">https://&lt;controller&gt;/api/auth/login</span>,
              Protect bootstrap at <span class="font-mono">https://&lt;controller&gt;/proxy/protect/api/bootstrap</span>,
              RTSP/RTSPS relay on port 7447 (sometimes 7441). Create the key in UniFi OS under
              Settings → Control Plane → Integrations.
            </p>
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
                size="xs"
                variant="ghost"
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
                  class="flex items-center gap-2 rounded-md border border-base-300 bg-sr-surface px-3 py-2 text-sm"
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
            <div :if={@show_controller_host?} class="space-y-2 md:col-span-2">
              <.input
                field={@form[:controller_host]}
                label={@controller_host_label}
                placeholder="controller.example.com or 10.0.0.1"
              />
              <p class="text-xs text-sr-muted">
                The management host this integration authenticates against, not one of the
                devices behind it. Hostname, IP, or <span class="font-mono">https://10.0.0.1</span>
                all work; ServiceRadar strips the URL down to the host. Leave blank only when
                the target query already resolves that host.
              </p>
            </div>
            <.input
              :if={@show_tls_policy?}
              field={@form[:tls_policy]}
              type="select"
              label="TLS Policy"
              options={enum_options(@provider_tls_policies)}
              required
            />
            <div :if={@show_tls_policy?} class="space-y-2 md:col-span-2">
              <.input
                field={@form[:ca_bundle_pem]}
                type="textarea"
                label="CA bundle (PEM)"
                placeholder="-----BEGIN CERTIFICATE-----"
              />
              <p class="text-xs text-sr-muted">
                Optional. Verify this rule's destinations against this anchor instead of the
                system trust store, for an appliance with a private or self-signed certificate.
                On Proxmox VE the cluster CA is <span class="font-mono">/etc/pve/pve-root-ca.pem</span>. Leave blank to use the
                system trust store.
              </p>
              <.input
                field={@form[:server_cert_fingerprint]}
                label="Server certificate fingerprint"
                placeholder="sha256:<64 hex characters>"
              />
              <p class="text-xs text-sr-muted">
                Optional alternative to a bundle: pin the leaf certificate. Supply one form of
                trust material or the other, not both.
              </p>
            </div>
            <.input
              :if={@show_ssh_policy?}
              field={@form[:ssh_host_key_policy]}
              type="select"
              label="SSH Host Key Policy"
              options={enum_options(@provider_ssh_host_key_policies)}
              required
            />
          </div>

          <input
            :if={@plugin_integration?}
            type="hidden"
            name={@form[:target_query].name}
            value="in:agents"
          />
          <div :if={@show_target_query?} class="space-y-2">
            <.input
              field={@form[:target_query]}
              type="textarea"
              label="Target Query"
              required
            />
            <p :if={@provider_value == "unifi-protect"} class="text-xs text-sr-muted">
              SRQL devices this rule applies to. Prefer
              <span class="font-mono">in:devices vendor:"Ubiquiti"</span>
              when the controller is in inventory. If it is not, keep a seed query that
              still matches at least one in-scope device and set the controller field
              above — the plugin calls that host, not the seed row IP.
            </p>
          </div>
          <fieldset :if={@plugin_integration?} class="space-y-4 border-t border-sr-line pt-4">
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
            <div class="space-y-2">
              <p class="text-sm font-medium text-sr-ink">
                When sources disagree, this source wins for
              </p>
              <label class="flex items-center gap-3 text-sm">
                <input
                  type="checkbox"
                  name="credential_rule[fact_authority][]"
                  value="switch_port_attachment"
                  class={ui_toggle_class()}
                  checked={"switch_port_attachment" in fact_authority_selected(@editing_rule)}
                />
                <span>Switch port</span>
              </label>
              <label class="flex items-center gap-3 text-sm">
                <input
                  type="checkbox"
                  name="credential_rule[fact_authority][]"
                  value="vlan_uid"
                  class={ui_toggle_class()}
                  checked={"vlan_uid" in fact_authority_selected(@editing_rule)}
                />
                <span>VLAN</span>
              </label>
            </div>
          </fieldset>
          <.input
            :if={@show_auto_discovery?}
            field={@form[:auto_discovery_enabled]}
            type="checkbox"
            label="Allow auto-discovery credential trials"
          />
          <.input :if={@show_allowed_ports?} field={@form[:allowed_ports]} label="Allowed Ports" />
          <.input field={@form[:description]} type="textarea" label="Description" />

          <div class="sr-ui-modal-action">
            <.ui_button navigate={~p"/settings/networks/credentials"} size="sm" variant="ghost">
              Cancel
            </.ui_button>
            <.ui_button type="submit" size="sm" variant="primary">Save</.ui_button>
          </div>
        </.form>
      </div>
    </dialog>
    """
  end

  defp open_credential_modal(socket, operation, id) do
    case CredentialManagement.open(operation, socket.assigns.current_scope, id) do
      {:ok, context} ->
        {:noreply, show_credential_modal(socket, operation, context)}

      {:error, :not_authorized} ->
        {:noreply, credential_action_unauthorized(socket)}

      {:error, :credential_not_found} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:error, "Credential not found")
         |> reload_page_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, credential_open_error(reason))}
    end
  end

  defp show_credential_modal(socket, :edit, context) do
    secret = context.secret

    socket
    |> assign(:current_scope, context.scope)
    |> assign(:credential_modal, %{kind: :edit, secret: secret})
    |> assign(
      :credential_form,
      credential_details_form(%{
        "id" => to_string(secret.id),
        "name" => secret.name,
        "description" => secret.description || ""
      })
    )
    |> assign(:credential_descriptor, nil)
    |> assign(:credential_modal_usage, :unavailable)
    |> assign(:credential_action_error, nil)
  end

  defp show_credential_modal(socket, :rotate, context) do
    socket
    |> assign(:current_scope, context.scope)
    |> assign(:credential_modal, %{kind: :rotate, secret: context.secret})
    |> assign(:credential_form, credential_rotation_form(context.secret.id))
    |> assign(:credential_descriptor, context.descriptor)
    |> assign(:credential_modal_usage, :unavailable)
    |> assign(:credential_action_error, nil)
  end

  defp show_credential_modal(socket, :delete, context) do
    socket
    |> assign(:current_scope, context.scope)
    |> assign(:credential_modal, %{kind: :delete, secret: context.secret})
    |> assign(:credential_form, credential_delete_form(context.secret.id))
    |> assign(:credential_descriptor, nil)
    |> assign(:credential_modal_usage, context.usage)
    |> assign(:credential_action_error, nil)
  end

  defp show_delete_block(socket, context, message) do
    socket
    |> show_credential_modal(:delete, context)
    |> assign(:credential_action_error, message)
  end

  defp reopen_delete_after_race(socket, id) do
    case CredentialManagement.open(:delete, socket.assigns.current_scope, id) do
      {:ok, context} ->
        {:noreply,
         show_delete_block(
           socket,
           context,
           "Credential became used before deletion completed"
         )}

      {:error, :not_authorized} ->
        {:noreply, credential_action_unauthorized(socket)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:error, "Credential could not be deleted")
         |> reload_page_data()}
    end
  end

  defp clear_credential_modal(socket) do
    socket
    |> assign(:credential_modal, nil)
    |> assign(:credential_form, nil)
    |> assign(:credential_descriptor, nil)
    |> assign(:credential_modal_usage, :unavailable)
    |> assign(:credential_action_error, nil)
  end

  defp credential_action_unauthorized(socket) do
    socket
    |> clear_credential_modal()
    |> put_flash(:error, "Not authorized to manage credentials")
    |> redirect(to: ~p"/settings/profile")
  end

  defp credential_details_form(params), do: to_form(params, as: :credential_details)

  defp credential_rotation_form(id), do: to_form(%{"id" => to_string(id)}, as: :credential_rotation)

  defp credential_delete_form(id), do: to_form(%{"id" => to_string(id), "confirmation_id" => ""}, as: :credential_delete)

  defp save_credential_rotation(socket, id, submitted_values) do
    case CredentialManagement.rotate(
           socket.assigns.current_scope,
           id,
           submitted_values,
           credential_management_opts(socket)
         ) do
      {:ok, _rotated} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:info, "Credential rotated")
         |> reload_page_data()}

      {:error, :not_authorized} ->
        {:noreply, credential_action_unauthorized(socket)}

      {:error, :credential_not_found} ->
        {:noreply,
         socket
         |> clear_credential_modal()
         |> put_flash(:error, "Credential not found")
         |> reload_page_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_rotation_form(id))
         |> assign(:credential_action_error, credential_rotation_error(reason))}
    end
  end

  defp credential_management_opts(%Phoenix.LiveView.Socket{private: private}) do
    Map.get(private, :credential_management_opts, [])
  end

  defp credential_open_error(:credential_rotation_not_supported), do: "This credential cannot be rotated"

  defp credential_open_error(:credential_descriptor_unavailable),
    do: "The approved credential descriptor is no longer available"

  defp credential_open_error(_reason), do: "Credential action could not be opened"

  defp credential_rotation_error({:missing_credential_field, field}), do: "#{credential_field_label(field)} is required"

  defp credential_rotation_error({:invalid_credential_field, field}), do: "#{credential_field_label(field)} is invalid"

  defp credential_rotation_error(:credential_descriptor_unavailable),
    do: "The approved credential descriptor is no longer available"

  defp credential_rotation_error(:credential_rotation_not_supported), do: "This credential cannot be rotated"

  defp credential_rotation_error(_reason), do: "Credential rotation failed"

  defp credential_field_label(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp load_page(socket, params) do
    socket =
      socket
      |> assign(:focused_credential_id, focused_credential_id(params["credential_id"]))
      |> reload_page_data()

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

    credential_usage_by_id =
      case CredentialManagement.usage_for_secrets(scope, secrets) do
        {:ok, usage_by_id} -> usage_by_id
        {:error, :credential_usage_unavailable} -> :unavailable
      end

    secret_names = Map.new(secrets, &{&1.id, secret_label(&1)})

    socket
    |> assign(:rules, rules)
    |> assign(:secrets, secrets)
    |> assign(:secret_options, Enum.map(secrets, &{secret_label(&1), &1.id}))
    |> assign(:secret_names, secret_names)
    |> assign(:credential_usage_by_id, credential_usage_by_id)
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
      {:ok, rule} ->
        _ = sync_fact_authority(rule, socket.assigns.current_scope)

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
      {:ok, rule} ->
        _ = sync_fact_authority(rule, socket.assigns.current_scope)

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

  defp sync_fact_authority(rule, scope) do
    metadata = normalize_metadata(rule.metadata)
    keys = fact_authority_selected(rule)
    instance = get_in(metadata, ["plugin_config", "instance_id"])

    ServiceRadar.Inventory.SourceFacts.Catalog.sync(
      "plugin_assignment",
      to_string(rule.id),
      to_string(rule.provider),
      instance,
      keys,
      actor: scope
    )
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
         |> assign(:secret_descriptor, nil)
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

    descriptor = credential_method(socket.assigns.integration_profiles, provider, auth_method)

    if secret_matches_rule?(secret, provider, descriptor) do
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
      "ca_bundle_pem" => form_string(form, :ca_bundle_pem),
      "server_cert_fingerprint" => form_string(form, :server_cert_fingerprint),
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
    providers = rule_provider_ids(integration_profiles)

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
         {:ok, tls_policy} <- tls_policy_param(params),
         {:ok, ssh_policy} <-
           ssh_host_key_policy_param(
             params,
             credential_method_descriptor(Map.get(integration_profiles, provider), auth_method)
           ),
         :ok <-
           validate_descriptor_transport(
             Map.get(integration_profiles, provider),
             auth_method,
             tls_policy,
             ssh_policy
           ),
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
         ca_bundle_pem: blank_to_nil(params["ca_bundle_pem"]),
         server_cert_fingerprint: blank_to_nil(params["server_cert_fingerprint"]),
         ssh_host_key_policy: ssh_policy,
         metadata: metadata
       }}
    end
  rescue
    ArgumentError -> {:error, "Required fields are missing"}
  end

  defp normalize_secret_params(%{"kind" => "descriptor"} = params, integration_profiles) do
    provider = required_string(params, "provider")
    auth_method = required_string(params, "auth_method")

    with %{} = descriptor <- credential_method(integration_profiles, provider, auth_method),
         {:ok, values} <- descriptor_secret_values(params["fields"], descriptor.method["fields"]),
         {:ok, attrs} <-
           CredentialSecretBuilder.build(
             descriptor.profile,
             auth_method,
             values,
             %{
               name: required_string(params, "name"),
               description: blank_to_nil(params["description"])
             }
           ) do
      {:ok, attrs}
    else
      nil ->
        {:error, "Credential descriptor is no longer available"}

      {:error, {:missing_credential_field, field}} ->
        {:error, "#{format_atom(field)} is required"}

      {:error, reason} ->
        {:error, "Credential could not be saved: #{format_error(reason)}"}
    end
  rescue
    ArgumentError -> {:error, "Required credential fields are missing"}
  end

  defp normalize_secret_params(_params, _integration_profiles), do: {:error, "Credential descriptor is required"}

  defp descriptor_secret_values(raw_values, fields) when is_map(raw_values) and is_list(fields) do
    values = Map.new(raw_values, fn {key, value} -> {to_string(key), to_string(value)} end)
    declared_ids = Enum.map(fields, & &1["id"])

    if Enum.any?(Map.keys(values), &(&1 not in declared_ids)) do
      {:error, "Credential form contains an undeclared field"}
    else
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
        id = field["id"]
        value = Map.get(values, id, "")
        size = byte_size(value)
        min_length = field["min_length"] || 0
        max_length = field["max_length"] || 16_384

        cond do
          field["required"] and String.trim(value) == "" ->
            {:halt, {:error, "#{field["label"]} is required"}}

          size < min_length or size > max_length ->
            {:halt, {:error, "#{field["label"]} has an invalid length"}}

          value == "" ->
            {:cont, {:ok, acc}}

          true ->
            {:cont, {:ok, Map.put(acc, id, value)}}
        end
      end)
    end
  end

  defp descriptor_secret_values(_raw_values, _fields), do: {:error, "Required credential fields are missing"}

  defp default_rule_params(params \\ %{}, integration_profiles \\ %{})

  defp default_rule_params(params, integration_profiles) do
    requested_provider = params |> Map.get("provider", "") |> to_string() |> String.trim()

    profile =
      Map.get(integration_profiles, requested_provider) || default_integration_profile(integration_profiles)

    cond do
      scheduled_integration_profile?(profile) -> scheduled_rule_defaults(profile)
      is_map(profile) -> manifest_rule_defaults(profile)
      true -> empty_rule_defaults()
    end
  end

  defp empty_rule_defaults do
    %{
      "name" => "",
      "description" => "",
      "provider" => "",
      "auth_method" => "",
      "purpose" => "",
      "purposes" => [],
      "target_query" => "",
      "scope_type" => "agent",
      "scope_value" => "",
      "secret_id" => "",
      "priority" => "100",
      "allowed_ports" => "",
      "tls_policy" => "verify",
      "ssh_host_key_policy" => "known_hosts",
      "controller_host" => "",
      "credential_use_roles" => "admin",
      "credential_use_principals" => "",
      "credential_use_groups" => "",
      "auto_discovery_enabled" => "false",
      "plugin_config" => %{},
      "schedule_enabled" => "false",
      "cadence_seconds" => "86400"
    }
  end

  defp manifest_rule_defaults(profile) do
    defaults = profile["rule_defaults"] || %{}
    purposes = defaults["purposes"] || profile["purposes"] || []

    empty_rule_defaults()
    |> Map.merge(defaults)
    |> Map.put("provider", profile["provider"])
    |> Map.put("auth_method", defaults["auth_method"] || first_auth_method(profile))
    |> Map.put("purposes", purposes)
    |> Map.put("purpose", List.first(purposes) || "")
  end

  defp scheduled_rule_defaults(profile) do
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
      "ca_bundle_pem" => rule.ca_bundle_pem || "",
      "server_cert_fingerprint" => rule.server_cert_fingerprint || "",
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
    profile = Map.get(integration_profiles, provider)
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
    |> put_descriptor_default("target_query", defaults["target_query"], integration_profiles)
    |> put_descriptor_default("allowed_ports", defaults["allowed_ports"], integration_profiles)
    |> Map.put_new("controller_host", "")
    |> put_plugin_defaults(profile, defaults)
    |> clear_unsupported_profile_fields(profile)
  end

  defp normalize_rule_form_params(_, integration_profiles), do: default_rule_params(%{}, integration_profiles)

  defp rule_form(params), do: to_form(params, as: :credential_rule)

  defp secret_form(params), do: to_form(params, as: :credential_secret)

  defp secret_form_title(_kind), do: "New Credential"

  defp provider_auth_methods(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile ->
        Enum.map(profile["auth_methods"], & &1["id"])

      nil ->
        []
    end
  end

  defp provider_purposes(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile ->
        profile["purposes"]

      nil ->
        []
    end
  end

  defp provider_scope_types(provider, integration_profiles) do
    case Map.get(integration_profiles, to_string(provider)) do
      %{} = profile ->
        profile["scope_types"]
        |> Enum.map(&resource_enum_value(:scope_type, &1))
        |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  defp normalize_provider(value, integration_profiles) do
    value = value |> to_string() |> String.trim()
    allowed = rule_provider_ids(integration_profiles)

    if value in allowed do
      value
    else
      case default_integration_profile(integration_profiles) do
        %{} = profile -> profile["provider"]
        nil -> ""
      end
    end
  end

  defp normalize_auth_method(provider, value, integration_profiles) do
    value = value |> to_string() |> String.trim()
    allowed = provider_auth_methods(provider, integration_profiles)
    Enum.find(allowed, &(to_string(&1) == value)) || List.first(allowed)
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

  defp primary_purpose(purposes), do: hd(purposes)

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

  defp ssh_host_key_policy_param(params, %{"ssh_host_key_policies" => policies})
       when is_list(policies) and policies != [] do
    allowed =
      policies
      |> Enum.map(&resource_enum_value(:ssh_host_key_policy, &1))
      |> Enum.reject(&is_nil/1)

    enum_param(params, "ssh_host_key_policy", allowed, "SSH host key policy")
  end

  defp ssh_host_key_policy_param(_params, _descriptor), do: {:ok, :known_hosts}

  # Mirrors ssh_host_key_policy_param/2: an absent param falls back to the
  # resource default rather than failing the save, so a provider whose form
  # does not render the control can still be saved. Only a param that is
  # present and unrecognized is an error.
  defp tls_policy_param(params) do
    case params |> Map.get("tls_policy", "") |> to_string() |> String.trim() do
      "" -> {:ok, :verify}
      _ -> enum_param(params, "tls_policy", @tls_policies, "TLS policy")
    end
  end

  defp validate_descriptor_transport(profile, auth_method, tls_policy, ssh_policy) do
    method = credential_method_descriptor(profile, auth_method)
    tls_policies = effective_tls_policies(method)
    ssh_policies = descriptor_values(method, "ssh_host_key_policies")

    cond do
      to_string(tls_policy) not in tls_policies ->
        {:error, "Selected authentication method does not allow this TLS policy"}

      ssh_policies != [] and to_string(ssh_policy) not in ssh_policies ->
        {:error, "Selected authentication method does not allow this SSH host key policy"}

      true ->
        :ok
    end
  end

  defp credential_use_policy_param(params, purposes) do
    if "console_access" in purposes do
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

  defp rule_metadata(params, _provider, purposes, profile, credential_use_policy) when is_map(profile) do
    if scheduled_integration_profile?(profile) do
      scheduled_rule_metadata(params, purposes, profile, credential_use_policy)
    else
      target_policy_rule_metadata(params, purposes, profile, credential_use_policy)
    end
  end

  defp rule_metadata(_params, _provider, _purposes, _profile, _credential_use_policy),
    do: {:error, "Credential descriptor is no longer available"}

  defp target_policy_rule_metadata(params, purposes, profile, credential_use_policy) do
    controls = profile_rule_controls(profile)

    metadata =
      maybe_put_metadata_string(
        %{
          "purposes" => Enum.map(purposes, &to_string/1),
          "auto_discovery_enabled" =>
            Map.get(controls, "auto_discovery_enabled", false) and
              boolean_param(params, "auto_discovery_enabled")
        },
        "host",
        params["controller_host"],
        Map.get(controls, "controller_host", false)
      )

    {:ok, maybe_put_credential_use_policy(metadata, credential_use_policy)}
  end

  defp scheduled_rule_metadata(params, purposes, profile, credential_use_policy) do
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
            "purposes" => Enum.map(purposes, &to_string/1),
            "schedule_enabled" => boolean_param(params, "schedule_enabled"),
            "cadence_seconds" => cadence_seconds,
            "fact_authority" => fact_authority_param(params)
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
      %{} = profile ->
        if scheduled_integration_profile?(profile) and scope != :agent,
          do: {:error, "Scheduled plugin integrations require agent scope"},
          else: :ok

      nil ->
        :ok
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

  defp put_descriptor_default(params, key, default, integration_profiles) do
    current = blank_to_nil(Map.get(params, key))

    known_defaults =
      integration_profiles
      |> Map.values()
      |> Enum.map(&get_in(&1, ["rule_defaults", key]))
      |> Enum.reject(&is_nil/1)

    if is_nil(current) or current in known_defaults,
      do: Map.put(params, key, default),
      else: params
  end

  defp put_plugin_defaults(params, profile, defaults) do
    if scheduled_integration_profile?(profile) do
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
    else
      params
    end
  end

  defp clear_unsupported_profile_fields(params, profile) do
    controls = profile_rule_controls(profile)

    params
    |> maybe_reset_field(
      "auto_discovery_enabled",
      "false",
      not Map.get(controls, "auto_discovery_enabled", false)
    )
    |> maybe_reset_field(
      "controller_host",
      "",
      not Map.get(controls, "controller_host", false)
    )
    |> maybe_reset_field(
      "ssh_host_key_policy",
      "known_hosts",
      descriptor_values(
        credential_method_descriptor(profile, Map.get(params, "auth_method")),
        "ssh_host_key_policies"
      ) == []
    )
  end

  defp maybe_reset_field(params, key, value, true), do: Map.put(params, key, value)
  defp maybe_reset_field(params, _key, _value, false), do: params

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
      "credential_use_policy",
      "fact_authority"
    ]
  end

  defp fact_authority_param(params) do
    params
    |> Map.get("fact_authority", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in ["switch_port_attachment", "vlan_uid"]))
  end

  defp fact_authority_selected(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("fact_authority", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp fact_authority_selected(_rule), do: []

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

  defp resource_enum_value(attribute_name, value) do
    allowed =
      NetworkCredentialRule
      |> Ash.Resource.Info.attribute(attribute_name)
      |> Map.get(:constraints, [])
      |> Keyword.get(:one_of, [])

    Enum.find(allowed, &(to_string(&1) == to_string(value)))
  end

  defp credential_method(integration_profiles, provider, method_id) do
    with %{} = profile <- Map.get(integration_profiles, to_string(provider)),
         %{} = method <-
           Enum.find(profile["auth_methods"] || [], &(&1["id"] == to_string(method_id))) do
      %{provider: profile["provider"], profile: profile, method: method}
    else
      _ -> nil
    end
  end

  defp credential_method_descriptor(profile, method_id) when is_map(profile) do
    Enum.find(profile["auth_methods"] || [], &(&1["id"] == to_string(method_id)))
  end

  defp credential_method_descriptor(_profile, _method_id), do: nil

  defp descriptor_values(descriptor, key, default \\ [])
  defp descriptor_values(%{} = descriptor, key, default), do: Map.get(descriptor, key, default)
  defp descriptor_values(_descriptor, _key, default), do: default

  # IntegrationDescriptor always materializes "tls_policies", normalizing an
  # absent manifest key to []. Core reads that as "any policy permitted"
  # (CredentialIntegration.allowed?/2), so the form must too: an empty list
  # narrows nothing and every policy stays on offer.
  #
  # An empty list therefore no longer distinguishes an SSH transport, which has
  # no TLS policy to choose. show_tls_policy? tests ssh_host_key_policies for
  # that instead.
  defp effective_tls_policies(descriptor) do
    case descriptor_values(descriptor, "tls_policies") do
      [] -> Enum.map(@tls_policies, &to_string/1)
      policies -> policies
    end
  end

  defp profile_rule_controls(%{} = profile), do: profile["rule_controls"] || %{}
  defp profile_rule_controls(_profile), do: %{}

  # "controller_host" is a generic rule control any profile may enable, and
  # IntegrationDescriptor has no slot for per-control copy (@allowed_rule_control_keys
  # is a closed allowlist whose values must be booleans). The descriptor label is the
  # only provider-specific text available, so it names the host and everything else
  # stays provider-neutral; per-provider guidance belongs in the profile banner and
  # the integration's docs page.
  defp controller_host_label(%{"label" => label}) when is_binary(label) and label != "", do: "#{label} controller host"

  defp controller_host_label(_profile), do: "Controller host"

  defp scheduled_integration_profile?(profile) when is_map(profile),
    do: get_in(profile, ["provisioning", "mode"]) == "producer_schedule"

  defp scheduled_integration_profile?(_profile), do: false

  defp default_integration_profile(integration_profiles) do
    profiles = rule_profile_list(integration_profiles)

    Enum.find(profiles, &Map.get(&1, "default", false)) ||
      Enum.min_by(profiles, &String.downcase(&1["label"] || &1["provider"]), fn -> nil end)
  end

  defp first_auth_method(profile), do: get_in(profile, ["auth_methods", Access.at(0), "id"]) || ""

  defp credential_method_list(integration_profiles) do
    integration_profiles
    |> integration_profile_list()
    |> Enum.flat_map(fn profile ->
      Enum.map(profile["auth_methods"] || [], fn method ->
        %{provider: profile["provider"], profile: profile, method: method}
      end)
    end)
  end

  defp open_descriptor_secret_form(socket, descriptor) do
    field_defaults =
      Map.new(descriptor.method["fields"], fn field ->
        {field["id"], Map.get(field, "default", "")}
      end)

    params = %{
      "kind" => "descriptor",
      "provider" => descriptor.provider,
      "auth_method" => descriptor.method["id"],
      "name" => "",
      "description" => "",
      "fields" => field_defaults
    }

    socket
    |> assign(:secret_descriptor, descriptor)
    |> assign(:secret_form, secret_form(params))
  end

  defp sanitize_secret_form_params(params, nil), do: params

  defp sanitize_secret_form_params(params, descriptor) do
    values = if is_map(params["fields"]), do: params["fields"], else: %{}

    sanitized =
      Map.new(descriptor.method["fields"], fn field ->
        value = if field["secret"], do: "", else: Map.get(values, field["id"], "")
        {field["id"], value}
      end)

    Map.put(params, "fields", sanitized)
  end

  defp descriptor_secret_title(nil), do: nil

  defp descriptor_secret_title(descriptor) do
    "New #{descriptor.profile["label"]} credential"
  end

  defp descriptor_field_value(_form, %{"secret" => true}), do: ""

  defp descriptor_field_value(%Form{params: params}, field) when is_map(params) do
    params
    |> Map.get("fields", %{})
    |> Map.get(field["id"], "")
  end

  defp descriptor_field_value(_form, _field), do: ""

  defp descriptor_field_input_type(%{"control" => "password"}), do: "password"
  defp descriptor_field_input_type(%{"control" => "textarea"}), do: "textarea"
  defp descriptor_field_input_type(_field), do: "text"

  defp provider_options(integration_profiles) do
    integration_profiles
    |> rule_profile_list()
    |> Enum.map(&{&1["label"], &1["provider"]})
  end

  defp integration_profile_list(integration_profiles) do
    integration_profiles
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1["label"] || &1["provider"]))
  end

  defp rule_profile_list(integration_profiles) do
    integration_profiles
    |> integration_profile_list()
    |> Enum.filter(&Map.get(&1, "supports_rules", true))
  end

  defp rule_provider_ids(integration_profiles) do
    integration_profiles
    |> rule_profile_list()
    |> Enum.map(& &1["provider"])
  end

  defp scheduled_integration_provider?(provider, integration_profiles),
    do: integration_profiles |> Map.get(to_string(provider)) |> scheduled_integration_profile?()

  defp form_plugin_config(%Form{params: params}) when is_map(params) do
    case Map.get(params, "plugin_config") do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp form_plugin_config(_form), do: %{}

  defp secret_options_for(secrets, provider, auth_method, selected_secret_id, integration_profiles) do
    descriptor = credential_method(integration_profiles, provider, auth_method)

    secrets
    |> Enum.filter(fn secret ->
      secret_matches_rule?(secret, provider, descriptor) or
        to_string(secret.id) == to_string(selected_secret_id)
    end)
    |> Enum.map(&{secret_label(&1), &1.id})
  end

  defp secret_matches_rule?(secret, provider, %{profile: profile, method: method}) do
    to_string(secret.provider) == to_string(provider) and
      to_string(secret.credential_kind) == method["credential_kind"] and
      secret_auth_method_matches?(secret, profile, method)
  end

  defp secret_matches_rule?(_secret, _provider, _descriptor), do: false

  defp secret_auth_method_matches?(secret, profile, method) do
    case secret |> Map.get(:metadata, %{}) |> normalize_metadata() |> Map.get("auth_method") do
      auth_method when is_binary(auth_method) and auth_method != "" ->
        auth_method == method["id"]

      _missing ->
        profile
        |> Map.get("auth_methods", [])
        |> Enum.count(&(&1["credential_kind"] == method["credential_kind"]))
        |> Kernel.==(1)
    end
  end

  defp secret_label(secret) do
    [secret.provider, secret.name, format_atom(secret.credential_kind)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp focused_credential_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp focused_credential_id(_value), do: nil

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.credentials.manage")

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
  end

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

  defp format_last_test(%{last_test_status: nil}), do: "Not tested"

  defp format_last_test(rule) do
    [format_atom(rule.last_test_status), rule.last_test_message]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
  end

  defp runtime_label(rule, profiles, schedules) do
    if scheduled_integration_provider?(rule.provider, profiles) do
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
    if scheduled_integration_provider?(rule.provider, profiles) do
      case Map.get(schedules, to_string(rule.id)) do
        %{enabled: true} -> "badge-success"
        %{} -> "badge-info"
        nil -> "badge-warning"
      end
    else
      if auto_discovery_enabled?(rule), do: "badge-warning", else: "badge-ghost"
    end
  end

  attr :rule, :map, required: true
  attr :profiles, :list, required: true
  attr :schedules, :map, required: true
  attr :timezone, :string, required: true

  defp runtime_status(assigns) do
    assigns =
      assign(
        assigns,
        :scheduled?,
        scheduled_integration_provider?(assigns.rule.provider, assigns.profiles)
      )

    ~H"""
    <%= if @scheduled? do %>
      <%= case Map.get(@schedules, to_string(@rule.id)) do %>
        <% %{last_status: status, last_run_at: last_run_at} -> %>
          {status} /
          <.user_time
            id={
              "settings-network-credential-rule-#{dom_id_segment(@rule.id)}-runtime-last-run-at"
            }
            value={last_run_at}
            timezone={@timezone}
            style={:compact}
            fallback="never"
          />
        <% nil -> %>
          Awaiting provisioning
      <% end %>
    <% else %>
      {format_last_test(@rule)}
    <% end %>
    """
  end

  defp format_atom(nil), do: nil

  defp format_atom(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_atom(value), do: to_string(value)

  defp dom_id_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)
  defp format_error({field, reason}), do: "#{field}: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")
  defp format_error(reason), do: inspect(reason)
end
