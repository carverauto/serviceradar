defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfileForm do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data, only: [agent_display_name: 1]
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.FormHelpers, only: [get_form_value: 3]

  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :selected_profile, :any, default: nil
  attr :target_device_count, :any, default: nil
  attr :target_entity, :string, default: "devices"
  attr :builder_open, :boolean, default: false
  attr :builder, :map, default: %{}
  attr :builder_sync, :boolean, default: true
  attr :targets, :list, default: []
  attr :selected_template_ids, :list, default: []
  attr :available_templates, :list, default: []
  attr :agents, :list, default: []
  attr :snmp_credentials, :list, default: []
  attr :save_credential_as_reusable, :boolean, default: false
  attr :credential_name, :string, default: ""

  def profile_form(assigns) do
    is_default = assigns.selected_profile && assigns.selected_profile.is_default
    config = Catalog.entity("interfaces")
    version = get_form_value(assigns.form, :version, "v2c")
    credential_secret_id = get_form_value(assigns.form, :credential_secret_id, "")
    credential_secret_id = to_string(credential_secret_id || "")

    selected_credential =
      Enum.find(
        assigns.snmp_credentials,
        &(to_string(&1.id) == credential_secret_id)
      )

    assigns =
      assigns
      |> assign(:is_default, is_default)
      |> assign(:config, config)
      |> assign(:version, version)
      |> assign(:credential_secret_id, credential_secret_id)
      |> assign(:selected_credential, selected_credential)
      |> assign(:credential_options, Data.snmp_credential_options(assigns.snmp_credentials))

    ~H"""
    <.ui_panel>
      <:header>
        <div class="text-sm font-semibold">
          {if @show_form == :new_profile,
            do: "New SNMP Profile",
            else: "Edit #{@selected_profile.name}"}
        </div>
      </:header>

      <.form
        for={@form}
        phx-submit="save_profile"
        phx-change="validate_profile"
        phx-debounce="300"
        class="space-y-6"
      >
        <!-- Basic Info Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted">
            Basic Information
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Profile Name</span>
              </label>
              <.input
                type="text"
                field={@form[:name]}
                class={ui_field_class(class: "w-full")}
                placeholder="e.g., Network Infrastructure"
                required
              />
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Poll Interval (seconds)</span>
              </label>
              <.input
                type="number"
                field={@form[:poll_interval]}
                class={ui_field_class(class: "w-full")}
                placeholder="60"
                min="10"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Timeout (seconds)</span>
              </label>
              <.input
                type="number"
                field={@form[:timeout]}
                class={ui_field_class(class: "w-full")}
                placeholder="5"
                min="1"
              />
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Retries</span>
              </label>
              <.input
                type="number"
                field={@form[:retries]}
                class={ui_field_class(class: "w-full")}
                placeholder="3"
                min="0"
              />
            </div>
          </div>

          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Description</span>
            </label>
            <.input
              type="textarea"
              field={@form[:description]}
              class={ui_field_class(class: "w-full min-h-24 py-2.5")}
              placeholder="Optional description of this profile's purpose"
              rows="2"
            />
          </div>
        </div>

        <!-- SNMP Credentials Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted">
            SNMP Credentials
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">SNMP Version</span>
              </label>
              <.input
                type="select"
                field={@form[:version]}
                class={ui_field_class(class: "w-full")}
                options={[
                  {"SNMPv1", "v1"},
                  {"SNMPv2c", "v2c"},
                  {"SNMPv3", "v3"}
                ]}
              />
            </div>

            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Reusable Credential</span>
              </label>
              <.input
                type="select"
                field={@form[:credential_secret_id]}
                class={ui_field_class(class: "w-full")}
                options={@credential_options}
              />
              <div class="flex items-start justify-between gap-3 text-xs text-sr-muted">
                <span :if={@credential_secret_id == ""}>
                  Stored on this profile only. Choose a reusable credential to share one
                  secret across profiles.
                </span>
                <span :if={@selected_credential}>
                  Reusable credential from the shared inventory. The fields below are ignored
                  while one is selected.
                </span>
                <span
                  :if={@credential_secret_id != "" and is_nil(@selected_credential)}
                  id="snmp-profile-reusable-credential-unavailable"
                  class="text-warning"
                >
                  The selected reusable credential is unavailable. Choose another credential
                  or store credentials on this profile.
                </span>
                <.reusable_credential_reference
                  :if={@selected_credential}
                  credential={@selected_credential}
                />
              </div>
            </div>
          </div>

          <%= if @credential_secret_id == "" do %>
            <%= if @version in ["v1", "v2c"] do %>
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Community String</span>
                </label>
                <.input
                  type="password"
                  name="form[community]"
                  value=""
                  class={ui_field_class(class: "w-full")}
                  placeholder={
                    if @show_form == :edit_profile,
                      do: "Leave blank to keep existing",
                      else: "e.g., public"
                  }
                  autocomplete="off"
                />
                <label class="flex items-center justify-between gap-2">
                  <span class="text-xs text-sr-muted">
                    Credentials are encrypted at rest.
                  </span>
                </label>
              </div>
            <% else %>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Username</span>
                  </label>
                  <.input
                    type="text"
                    field={@form[:username]}
                    class={ui_field_class(class: "w-full")}
                    placeholder="e.g., snmpuser"
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Security Level</span>
                  </label>
                  <.input
                    type="select"
                    field={@form[:security_level]}
                    class={ui_field_class(class: "w-full")}
                    options={[
                      {"No Auth, No Privacy", "no_auth_no_priv"},
                      {"Auth, No Privacy", "auth_no_priv"},
                      {"Auth + Privacy", "auth_priv"}
                    ]}
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Auth Protocol</span>
                  </label>
                  <.input
                    type="select"
                    field={@form[:auth_protocol]}
                    class={ui_field_class(class: "w-full")}
                    options={[
                      {"MD5", "md5"},
                      {"SHA", "sha"},
                      {"SHA-224", "sha224"},
                      {"SHA-256", "sha256"},
                      {"SHA-384", "sha384"},
                      {"SHA-512", "sha512"}
                    ]}
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Auth Password</span>
                  </label>
                  <.input
                    type="password"
                    name="form[auth_password]"
                    value=""
                    class={ui_field_class(class: "w-full")}
                    placeholder={
                      if @show_form == :edit_profile,
                        do: "Leave blank to keep existing",
                        else: "Auth password"
                    }
                    autocomplete="off"
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Privacy Protocol</span>
                  </label>
                  <.input
                    type="select"
                    field={@form[:priv_protocol]}
                    class={ui_field_class(class: "w-full")}
                    options={[
                      {"DES", "des"},
                      {"AES", "aes"},
                      {"AES-192", "aes192"},
                      {"AES-256", "aes256"}
                    ]}
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Privacy Password</span>
                  </label>
                  <.input
                    type="password"
                    name="form[priv_password]"
                    value=""
                    class={ui_field_class(class: "w-full")}
                    placeholder={
                      if @show_form == :edit_profile,
                        do: "Leave blank to keep existing",
                        else: "Privacy password"
                    }
                    autocomplete="off"
                  />
                </div>
              </div>

              <p class="text-xs text-sr-muted">
                Leave password fields blank to keep existing values. Credentials are encrypted at rest.
              </p>
            <% end %>

            <div class="rounded-md border border-sr-line/60 p-3 space-y-3">
              <label class="flex items-start gap-2">
                <input type="hidden" name="form[save_credential_as_reusable]" value="false" />
                <input
                  type="checkbox"
                  name="form[save_credential_as_reusable]"
                  value="true"
                  class="mt-1 checkbox checkbox-sm"
                  checked={@save_credential_as_reusable}
                />
                <span class="text-sm text-sr-ink">
                  Also save this credential for reuse
                  <span class="block text-xs text-sr-muted">
                    Stores it in the shared inventory and binds this profile to it, so other
                    profiles and targets can use the same credential instead of a separate copy.
                  </span>
                </span>
              </label>

              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Credential name</span>
                </label>
                <.input
                  type="text"
                  name="form[credential_name]"
                  value={@credential_name}
                  class={ui_field_class(class: "w-full")}
                  placeholder="e.g., Core switches read-only"
                  autocomplete="off"
                />
              </div>
            </div>
          <% end %>
        </div>

        <!-- Agent Targeting Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted">
            Agent Targeting
          </h3>

          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Agents</span>
            </label>
            <% selected_agents = Enum.map(@form[:agent_ids].value || [], &to_string/1) %>
            <!-- Hidden empty entry so unchecking every box submits [] (legacy all-agents). -->
            <input type="hidden" name="form[agent_ids][]" value="" />
            <%= if @agents == [] do %>
              <p class="text-sm text-sr-muted">
                No active agents available. Leave unset to run this profile on all SNMP-capable agents.
              </p>
            <% else %>
              <div class="flex flex-wrap gap-4">
                <%= for agent <- @agents do %>
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="form[agent_ids][]"
                      value={agent.uid}
                      class={ui_checkbox_class()}
                      checked={Enum.member?(selected_agents, to_string(agent.uid))}
                    />
                    <span>{agent_display_name(agent)}</span>
                  </label>
                <% end %>
              </div>
            <% end %>
            <label class="flex items-center justify-between gap-2">
              <span class="text-xs text-sr-muted">
                Pin this profile to specific agents. Leave all unchecked to run on every SNMP-capable agent (legacy behavior).
              </span>
            </label>
          </div>
        </div>

        <!-- Interface Targeting Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted">
            Interface Targeting
          </h3>

          <div class="space-y-4">
            <div :if={@is_default} class="bg-info/10 border border-info/30 rounded-lg p-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-information-circle" class="size-5 text-info shrink-0 mt-0.5" />
                <div>
                  <p class="text-sm font-medium">Default Profile</p>
                  <p class="text-xs text-sr-muted mt-1">
                    This profile acts as the fallback for any interfaces that don't match other profiles.
                    You can still set a targeting query here to scope the default and preview counts.
                  </p>
                </div>
              </div>
            </div>

            <!-- Query Input with Builder Toggle -->
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Target Query (SRQL)</span>
              </label>
              <div class="flex items-center gap-2">
                <div class="flex-1">
                  <.input
                    type="text"
                    field={@form[:target_query]}
                    class={ui_field_class(mono: true, class: "w-full text-sm")}
                    placeholder="e.g., in:interfaces type:ethernet device.hostname:%router%"
                  />
                </div>
                <.ui_icon_button
                  active={@builder_open}
                  aria-label="Toggle query builder"
                  title="Query builder"
                  phx-click="builder_toggle"
                >
                  <.icon name="hero-adjustments-horizontal" class="size-4" />
                </.ui_icon_button>
              </div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  SRQL filters to match interfaces. Examples: <code class="bg-sr-subtle px-1 rounded">type:ethernet</code>,
                  <code class="bg-sr-subtle px-1 rounded">device.hostname:%router%</code>
                </span>
              </label>
            </div>

            <!-- Visual Query Builder -->
            <div :if={@builder_open} class="border border-sr-line rounded-lg p-4 bg-sr-surface/50">
              <div class="flex items-center justify-between mb-4">
                <div class="text-sm font-semibold">Query Builder</div>
                <div class="flex items-center gap-2">
                  <.ui_badge :if={not @builder_sync} size="sm">Not applied</.ui_badge>
                  <.ui_button
                    :if={not @builder_sync}
                    size="sm"
                    variant="ghost"
                    type="button"
                    phx-click="builder_apply"
                  >
                    Apply to query
                  </.ui_button>
                </div>
              </div>

              <form phx-change="builder_change" autocomplete="off">
                <div class="flex flex-col gap-4">
                  <!-- Filters Section -->
                  <div class="flex flex-col gap-3">
                    <div class="text-xs text-sr-muted font-medium">
                      Match interfaces where:
                    </div>

                    <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                      <div class="flex items-center gap-3">
                        <.query_builder_pill label="Filter">
                          <%= if @config.filter_fields == [] do %>
                            <.ui_inline_input
                              type="text"
                              name={"builder[filters][#{idx}][field]"}
                              value={filter["field"] || ""}
                              placeholder="field"
                              class="w-40 placeholder:text-sr-muted"
                            />
                          <% else %>
                            <.ui_inline_select name={"builder[filters][#{idx}][field]"}>
                              <%= for field <- @config.filter_fields do %>
                                <option value={field} selected={filter["field"] == field}>
                                  {field}
                                </option>
                              <% end %>
                            </.ui_inline_select>
                          <% end %>

                          <.ui_inline_select
                            name={"builder[filters][#{idx}][op]"}
                            class="text-xs text-sr-muted"
                          >
                            <option
                              value="contains"
                              selected={(filter["op"] || "contains") == "contains"}
                            >
                              contains
                            </option>
                            <option value="not_contains" selected={filter["op"] == "not_contains"}>
                              does not contain
                            </option>
                            <option value="equals" selected={filter["op"] == "equals"}>
                              equals
                            </option>
                            <option value="not_equals" selected={filter["op"] == "not_equals"}>
                              does not equal
                            </option>
                          </.ui_inline_select>

                          <.ui_inline_input
                            type="text"
                            name={"builder[filters][#{idx}][value]"}
                            value={filter["value"] || ""}
                            placeholder="value"
                            class="placeholder:text-sr-muted w-48"
                          />
                        </.query_builder_pill>

                        <.ui_icon_button
                          size="xs"
                          aria-label="Remove filter"
                          title="Remove filter"
                          type="button"
                          phx-click="builder_remove_filter"
                          phx-value-idx={idx}
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </.ui_icon_button>
                      </div>
                    <% end %>

                    <button
                      type="button"
                      class="inline-flex items-center gap-2 rounded-md border border-dashed border-sr-brand/40 px-3 py-2 text-sm text-sr-brand/80 hover:bg-sr-brand/5 w-fit"
                      phx-click="builder_add_filter"
                    >
                      <.icon name="hero-plus" class="size-4" /> Add filter
                    </button>
                  </div>
                </div>
              </form>
            </div>

            <!-- Target Count Preview -->
            <div :if={@target_device_count != nil} class="flex items-center gap-2">
              <.icon name="hero-signal" class="size-4 text-sr-muted" />
              <span class="text-sm">
                <%= case @target_device_count do %>
                  <% {:ok, count} -> %>
                    <span class="font-semibold">{count}</span>
                    <span class="text-sr-muted">
                      device(s) match this {if @target_entity == "interfaces",
                        do: "interface",
                        else: "device"} query
                    </span>
                  <% _ -> %>
                    <span class="font-semibold">Unknown</span>
                    <span class="text-sr-muted">targets for this query</span>
                <% end %>
              </span>
              <.ui_badge variant="ghost" size="xs">
                {if @target_entity == "interfaces", do: "Interfaces", else: "Devices"}
              </.ui_badge>
            </div>

            <!-- Priority -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Priority</span>
                </label>
                <.input
                  type="number"
                  field={@form[:priority]}
                  class={ui_field_class(class: "w-full")}
                  min="0"
                  max="100"
                />
                <label class="flex items-center justify-between gap-2">
                  <span class="text-xs text-sr-muted">
                    Higher priority profiles are evaluated first (0-100)
                  </span>
                </label>
              </div>
            </div>
          </div>
        </div>

        <!-- OID Templates Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted">
            OID Templates
          </h3>
          <p class="text-sm text-sr-muted">
            Select OID templates to define what metrics are polled from devices matched by this profile.
          </p>

          <!-- Selected Templates -->
          <div :if={@selected_template_ids != []} class="flex flex-wrap gap-2">
            <%= for template_id <- @selected_template_ids do %>
              <% template = Enum.find(@available_templates, &(&1.id == template_id)) %>
              <div
                :if={template}
                class="inline-flex items-center gap-2 px-3 py-1.5 bg-sr-brand/10 text-sr-brand rounded-full text-sm"
              >
                <span>{template.name}</span>
                <button
                  type="button"
                  class="hover:bg-sr-brand/20 rounded-full p-0.5"
                  phx-click="remove_template"
                  phx-value-id={template_id}
                  title="Remove template"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            <% end %>
          </div>

          <!-- Template Dropdown -->
          <.ui_dropdown
            align="start"
            class="w-full max-w-md"
            menu_class="w-full max-w-md min-w-full max-h-60 overflow-y-auto"
          >
            <:trigger>
              <.ui_button type="button" size="sm" variant="outline" class="w-full justify-between">
                <span class="inline-flex items-center">
                  <.icon name="hero-plus" class="mr-2 size-4" /> Add OID Template
                </span>
                <.icon name="hero-chevron-down" class="size-4" />
              </.ui_button>
            </:trigger>
            <:item :if={@available_templates == []}>
              <span>No templates available</span>
            </:item>
            <:item :for={template <- @available_templates}>
              <% selected = template.id in @selected_template_ids %>
              <button
                type="button"
                class={[
                  "flex w-full items-center justify-between",
                  selected && "bg-sr-brand/10"
                ]}
                phx-click="toggle_template"
                phx-value-id={template.id}
              >
                <div class="flex flex-col items-start">
                  <span class="font-medium">{template.name}</span>
                  <span class="text-xs text-sr-muted">
                    {template.vendor} · {template.oid_count} OID(s)
                  </span>
                </div>
                <.icon :if={selected} name="hero-check" class="size-4 text-sr-brand" />
              </button>
            </:item>
          </.ui_dropdown>

          <p class="text-xs text-sr-muted">
            OID templates define which SNMP metrics (OIDs) to poll. Select one or more templates to monitor
            interface traffic, CPU/memory, environment sensors, or other vendor-specific metrics.
          </p>
        </div>

        <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-sr-line">
          <.link navigate={~p"/settings/snmp"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            {if @show_form == :new_profile, do: "Create Profile", else: "Save Changes"}
          </.ui_button>
        </div>
      </.form>

      <!-- Legacy SNMP Targets Section (deprecated, only shown when existing targets present) -->
      <div
        :if={@show_form == :edit_profile && @targets != []}
        class="mt-6 pt-6 border-t border-sr-line"
      >
        <div class="bg-warning/10 border border-warning/30 rounded-lg p-4 mb-4">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
            <div>
              <p class="text-sm font-medium">Legacy Configuration</p>
              <p class="text-xs text-sr-muted mt-1">
                Manual SNMP targets are deprecated. Targets are now automatically derived from devices
                matched by the target query. Existing targets will continue to work but cannot be edited.
                Configure SNMP credentials on individual devices in the Inventory section.
              </p>
            </div>
          </div>
        </div>

        <h3 class="text-sm font-semibold uppercase tracking-wide text-sr-muted mb-4">
          Legacy Manual Targets ({length(@targets)})
        </h3>

        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm", class: "opacity-75")}>
            <thead>
              <tr class="text-xs uppercase tracking-wide text-sr-muted">
                <th>Name</th>
                <th>Host</th>
                <th>Port</th>
                <th>Version</th>
              </tr>
            </thead>
            <tbody>
              <%= for target <- @targets do %>
                <tr class="hover:bg-sr-subtle/40">
                  <td class="font-medium">{target.name}</td>
                  <td class="font-mono text-xs">{target.host}</td>
                  <td class="font-mono text-xs">{target.port}</td>
                  <td>
                    <.ui_badge variant={version_badge_variant(target.version)} size="xs">
                      {format_version(target.version)}
                    </.ui_badge>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :credential, :any, required: true

  def reusable_credential_reference(assigns) do
    ~H"""
    <.link
      id="snmp-profile-reusable-credential-link"
      navigate={credential_inventory_path(@credential.id)}
      class="shrink-0 font-medium text-sr-brand hover:underline"
    >
      View reusable credential
    </.link>
    """
  end

  defp credential_inventory_path(secret_id) do
    ~p"/settings/networks/credentials?credential_id=#{secret_id}" <>
      "#credential-secret-#{secret_id}"
  end

  def version_badge_variant(:v1), do: "ghost"
  def version_badge_variant(:v2c), do: "info"
  def version_badge_variant(:v3), do: "success"
  def version_badge_variant(_), do: "ghost"

  def format_version(:v1), do: "v1"
  def format_version(:v2c), do: "v2c"
  def format_version(:v3), do: "v3"
  def format_version(v) when is_binary(v), do: v
  def format_version(_), do: "v2c"
end
