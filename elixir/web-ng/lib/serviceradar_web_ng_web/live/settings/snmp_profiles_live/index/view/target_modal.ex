defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.TargetModal do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.FormHelpers, only: [get_form_value: 3]

  attr :form, :any, required: true
  attr :editing_target, :any, default: nil
  attr :show_password, :boolean, default: false
  attr :target_oids, :list, default: []
  attr :test_connection_result, :map, default: nil
  attr :test_connection_loading, :boolean, default: false

  def target_modal(assigns) do
    version = get_form_value(assigns.form, :version, "v2c")

    assigns = assign(assigns, :version, version)

    ~H"""
    <.ui_modal id="target_modal" size="md" on_cancel="close_target_modal">
      <:title>
        {if @editing_target, do: "Edit SNMP Target", else: "Add SNMP Target"}
      </:title>

      <.form
        for={@form}
        phx-submit="save_target"
        phx-change="validate_target"
        class="space-y-6"
      >
        <!-- Connection Settings -->
        <div class="space-y-4">
          <h4 class="text-sm font-semibold text-sr-muted">Connection</h4>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Target Name</span>
              </label>
              <.input
                type="text"
                field={@form[:name]}
                class={ui_field_class(class: "w-full")}
                placeholder="e.g., Core Router 1"
                required
              />
            </div>
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
          </div>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div class="md:col-span-2">
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Host</span>
              </label>
              <.input
                type="text"
                field={@form[:host]}
                class={ui_field_class(class: "w-full")}
                placeholder="e.g., 192.168.1.1 or router.local"
                required
              />
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Port</span>
              </label>
              <.input
                type="number"
                field={@form[:port]}
                class={ui_field_class(class: "w-full")}
                placeholder="161"
                min="1"
                max="65535"
              />
            </div>
          </div>
        </div>

        <!-- Authentication based on version -->
        <div class="space-y-4">
          <h4 class="text-sm font-semibold text-sr-muted">Authentication</h4>

          <%= if @version in ["v1", "v2c"] do %>
            <!-- SNMPv1/v2c: Community String -->
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Community String</span>
              </label>
              <div class="flex items-center gap-2">
                <.input
                  type={if @show_password, do: "text", else: "password"}
                  name="form[community]"
                  value=""
                  class={ui_field_class(class: "w-full")}
                  placeholder={
                    if @editing_target, do: "Enter new value to change", else: "e.g., public"
                  }
                  autocomplete="off"
                />
                <.ui_icon_button
                  type="button"
                  phx-click="toggle_password_visibility"
                  title={if @show_password, do: "Hide", else: "Show"}
                >
                  <.icon
                    name={if @show_password, do: "hero-eye-slash", else: "hero-eye"}
                    class="size-4"
                  />
                </.ui_icon_button>
              </div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs text-sr-muted">
                  <%= if @editing_target do %>
                    Leave blank to keep existing value
                  <% else %>
                    The community string is encrypted at rest
                  <% end %>
                </span>
              </label>
            </div>
          <% else %>
            <!-- SNMPv3: Full authentication -->
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
                <div class="flex items-center gap-2">
                  <.input
                    type={if @show_password, do: "text", else: "password"}
                    name="form[auth_password]"
                    value=""
                    class={ui_field_class(class: "w-full")}
                    placeholder={if @editing_target, do: "Enter to change", else: "Auth password"}
                    autocomplete="off"
                  />
                  <.ui_icon_button
                    type="button"
                    phx-click="toggle_password_visibility"
                    title={if @show_password, do: "Hide", else: "Show"}
                  >
                    <.icon
                      name={if @show_password, do: "hero-eye-slash", else: "hero-eye"}
                      class="size-4"
                    />
                  </.ui_icon_button>
                </div>
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
                  type={if @show_password, do: "text", else: "password"}
                  name="form[priv_password]"
                  value=""
                  class={ui_field_class(class: "w-full")}
                  placeholder={if @editing_target, do: "Enter to change", else: "Privacy password"}
                  autocomplete="off"
                />
              </div>
            </div>

            <p class="text-xs text-sr-muted">
              <%= if @editing_target do %>
                Leave password fields blank to keep existing values. Credentials are encrypted at rest.
              <% else %>
                All passwords are encrypted at rest using AES-256-GCM.
              <% end %>
            </p>
          <% end %>
        </div>

        <!-- OIDs Section -->
        <div class="space-y-4">
          <div class="flex items-center justify-between">
            <h4 class="text-sm font-semibold text-sr-muted">OIDs to Monitor</h4>
            <div class="flex items-center gap-2">
              <.ui_button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="open_template_browser"
              >
                <.icon name="hero-document-duplicate" class="size-4" /> Use Template
              </.ui_button>
              <.ui_button
                type="button"
                variant="ghost"
                size="sm"
                phx-click="add_oid"
              >
                <.icon name="hero-plus" class="size-4" /> Add OID
              </.ui_button>
            </div>
          </div>

          <div
            :if={@target_oids == []}
            class="text-center py-6 text-sr-muted bg-sr-subtle/30 rounded-lg"
          >
            <.icon name="hero-variable" class="size-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">No OIDs configured</p>
            <p class="text-xs mt-1">Add OIDs manually or select from a template</p>
          </div>

          <div :if={@target_oids != []} class="space-y-3">
            <%= for {oid, idx} <- Enum.with_index(@target_oids) do %>
              <div class="flex items-start gap-2 p-3 bg-sr-subtle/30 rounded-lg">
                <div class="flex-1 grid grid-cols-1 md:grid-cols-6 gap-2">
                  <div class="md:col-span-2">
                    <input
                      type="text"
                      value={oid["oid"]}
                      placeholder=".1.3.6.1.2.1.1.1.0"
                      class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                      phx-blur="update_oid"
                      phx-value-index={idx}
                      phx-value-field="oid"
                      name={"oid_#{idx}_oid"}
                    />
                    <span class="text-[10px] text-sr-muted">OID</span>
                  </div>
                  <div class="md:col-span-2">
                    <input
                      type="text"
                      value={oid["name"]}
                      placeholder="sysDescr"
                      class={ui_field_class(size: "sm", class: "w-full text-xs")}
                      phx-blur="update_oid"
                      phx-value-index={idx}
                      phx-value-field="name"
                      name={"oid_#{idx}_name"}
                    />
                    <span class="text-[10px] text-sr-muted">Name</span>
                  </div>
                  <div>
                    <select
                      class={ui_field_class(size: "sm", class: "w-full text-xs")}
                      phx-change="update_oid"
                      phx-value-index={idx}
                      phx-value-field="data_type"
                      name={"oid_#{idx}_data_type"}
                    >
                      <option value="gauge" selected={oid["data_type"] == "gauge"}>Gauge</option>
                      <option value="counter" selected={oid["data_type"] == "counter"}>
                        Counter
                      </option>
                      <option value="string" selected={oid["data_type"] == "string"}>String</option>
                      <option value="timeticks" selected={oid["data_type"] == "timeticks"}>
                        Timeticks
                      </option>
                    </select>
                    <span class="text-[10px] text-sr-muted">Type</span>
                  </div>
                  <div>
                    <select
                      class={ui_field_class(size: "sm", class: "w-full text-xs")}
                      phx-change="update_oid"
                      phx-value-index={idx}
                      phx-value-field="mode"
                      name={"oid_#{idx}_mode"}
                    >
                      <option value="get" selected={oid["mode"] in [nil, "get", ""]}>GET</option>
                      <option value="walk" selected={oid["mode"] == "walk"}>Walk</option>
                    </select>
                    <span class="text-[10px] text-sr-muted">Mode</span>
                  </div>
                  <div class="flex items-center gap-2">
                    <label class="flex items-center gap-1 cursor-pointer">
                      <input
                        type="checkbox"
                        class={ui_checkbox_class()}
                        checked={oid["delta"] == true or oid["delta"] == "true"}
                        phx-click="update_oid"
                        phx-value-index={idx}
                        phx-value-field="delta"
                        phx-value-delta={to_string(!(oid["delta"] == true or oid["delta"] == "true"))}
                      />
                      <span class="text-xs">Delta</span>
                    </label>
                  </div>
                </div>
                <.ui_icon_button
                  type="button"
                  size="sm"
                  phx-click="remove_oid"
                  phx-value-index={idx}
                  title="Remove OID"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.ui_icon_button>
              </div>
            <% end %>
          </div>

          <p class="text-xs text-sr-muted">
            Configure which SNMP OIDs to poll from this target. Use templates for common device types.
          </p>
        </div>

        <!-- Test Connection -->
        <div class="space-y-3">
          <div class="flex items-center gap-3">
            <.ui_button
              type="button"
              variant="outline"
              size="sm"
              phx-click="test_connection"
              disabled={@test_connection_loading}
            >
              <%= if @test_connection_loading do %>
                <.ui_spinner size="xs" class="mr-2" /> Testing...
              <% else %>
                <.icon name="hero-signal" class="size-4 mr-2" /> Test Connection
              <% end %>
            </.ui_button>
            <span class="text-xs text-sr-muted">
              Verify connectivity to the SNMP agent
            </span>
          </div>

          <!-- Test Result -->
          <%= if @test_connection_result do %>
            <div class={[
              "flex items-center gap-2 p-3 rounded-lg text-sm",
              @test_connection_result.success && "bg-success/10 text-success",
              !@test_connection_result.success && "bg-error/10 text-error"
            ]}>
              <%= if @test_connection_result.success do %>
                <.icon name="hero-check-circle" class="size-5" />
              <% else %>
                <.icon name="hero-x-circle" class="size-5" />
              <% end %>
              <span>{@test_connection_result.message}</span>
            </div>
          <% end %>
        </div>

        <!-- Modal Actions -->
        <div class="sr-ui-modal-action">
          <.ui_button type="button" variant="ghost" phx-click="close_target_modal">
            Cancel
          </.ui_button>
          <.ui_button type="submit" variant="primary">
            {if @editing_target, do: "Save Changes", else: "Add Target"}
          </.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end
end
