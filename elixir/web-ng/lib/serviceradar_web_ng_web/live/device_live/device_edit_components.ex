defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceEditComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  attr(:device_row, :map, default: nil)
  attr(:device_form, :any, required: true)
  attr(:device_snmp_credential, :any, default: nil)
  attr(:snmp_credential_form, :any, required: true)

  def device_edit_section(assigns) do
    ~H"""
    <div class="rounded-xl border border-sr-brand/30 bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line bg-sr-brand/5 flex items-center justify-between">
        <div class="flex items-center gap-2">
          <.icon name="hero-pencil-square" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Edit Device Details</span>
        </div>
        <div class="flex items-center gap-2">
          <.ui_button phx-click="toggle_edit" variant="ghost" size="xs">
            Cancel
          </.ui_button>
          <.ui_button type="submit" form="device-edit-form" variant="primary" size="xs">
            <.icon name="hero-check" class="size-3" /> Save
          </.ui_button>
        </div>
      </div>

      <.form
        for={@device_form}
        id="device-edit-form"
        phx-change="validate_device"
        phx-submit="save_device"
        class="p-4"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Hostname</span>
            </label>
            <input
              type="text"
              name="device[hostname]"
              value={@device_form[:hostname].value}
              class={ui_field_class(size: "sm")}
              phx-debounce="300"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">IP Address</span>
            </label>
            <input
              type="text"
              name="device[ip]"
              value={@device_form[:ip].value}
              class={ui_field_class(size: "sm", mono: true)}
              phx-debounce="300"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Type</span>
            </label>
            <select name="device[type]" class={ui_field_class(size: "sm")}>
              <option value="">Select type...</option>
              <option value="server" selected={@device_form[:type].value == "server"}>
                Server
              </option>
              <option value="workstation" selected={@device_form[:type].value == "workstation"}>
                Workstation
              </option>
              <option value="router" selected={@device_form[:type].value == "router"}>
                Router
              </option>
              <option value="switch" selected={@device_form[:type].value == "switch"}>
                Switch
              </option>
              <option value="firewall" selected={@device_form[:type].value == "firewall"}>
                Firewall
              </option>
              <option value="printer" selected={@device_form[:type].value == "printer"}>
                Printer
              </option>
              <option value="other" selected={@device_form[:type].value == "other"}>
                Other
              </option>
            </select>
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Vendor</span>
            </label>
            <input
              type="text"
              name="device[vendor_name]"
              value={@device_form[:vendor_name].value}
              class={ui_field_class(size: "sm")}
              phx-debounce="300"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Model</span>
            </label>
            <input
              type="text"
              name="device[model]"
              value={@device_form[:model].value}
              class={ui_field_class(size: "sm")}
              phx-debounce="300"
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Gateway</span>
            </label>
            <input
              type="text"
              value={Map.get(@device_row, "gateway_id", "")}
              class={ui_field_class(size: "sm", mono: true, class: "bg-sr-subtle")}
              disabled
            />
            <label class="flex items-center justify-between gap-2 py-0">
              <span class="text-xs text-sr-muted">Read-only</span>
            </label>
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Managed</span>
            </label>
            <input
              type="hidden"
              name="device[is_managed]"
              value={if agent_device?(@device_row), do: "true", else: "false"}
            />
            <label class="inline-flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name="device[is_managed]"
                value="true"
                checked={truthy?(@device_form[:is_managed].value)}
                disabled={agent_device?(@device_row)}
                class={ui_checkbox_class(size: "xs")}
              />
              <span>Mark as managed</span>
            </label>
            <label
              :if={agent_device?(@device_row)}
              class="flex items-center justify-between gap-2 py-0"
            >
              <span class="text-xs text-sr-muted">
                Agent devices are always managed.
              </span>
            </label>
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="flex items-center justify-between gap-2 py-1">
              <span class="text-xs font-medium text-sr-ink font-medium">Trusted</span>
            </label>
            <input type="hidden" name="device[is_trusted]" value="false" />
            <label class="inline-flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name="device[is_trusted]"
                value="true"
                checked={truthy?(@device_form[:is_trusted].value)}
                class={ui_checkbox_class(size: "xs")}
              />
              <span>Mark as trusted</span>
            </label>
          </div>
        </div>

        <div class="flex flex-col gap-1.5 mt-4">
          <label class="flex items-center justify-between gap-2 py-1">
            <span class="text-xs font-medium text-sr-ink font-medium">Tags</span>
            <span class="text-xs text-sr-muted">
              One per line (key or key=value)
            </span>
          </label>
          <textarea
            name="device[tags]"
            class={ui_field_class(size: "sm", class: "h-20 py-2")}
            phx-debounce="300"
          >{@device_form[:tags].value}</textarea>
        </div>
      </.form>

      <div class="border-t border-sr-line px-4 py-4">
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center gap-2">
            <.icon name="hero-lock-closed" class="size-4 text-sr-muted" />
            <span class="text-sm font-semibold">SNMP Credentials Override</span>
            <span
              :if={@device_snmp_credential}
              class="inline-flex items-center rounded-full bg-success/10 px-2 py-0.5 text-[11px] font-semibold text-success"
            >
              Override active
            </span>
          </div>
          <.ui_button
            :if={@device_snmp_credential}
            type="button"
            variant="ghost"
            size="xs"
            phx-click="clear_snmp_credentials"
          >
            Clear Override
          </.ui_button>
        </div>
        <p class="mb-4 text-xs text-sr-muted">
          A device override wins over the matching SNMP profile credential. Profile targeting,
          poll interval, and OID templates still come from <.link
            href="/settings/snmp"
            class="link link-hover"
          >SNMP profiles</.link>.
        </p>

        <.form
          for={@snmp_credential_form}
          id="device-snmp-credential-form"
          phx-change="snmp_form_change"
          phx-submit="save_snmp_credentials"
          class="space-y-4"
        >
          <% snmp_version =
            Phoenix.HTML.Form.input_value(@snmp_credential_form, :version) || "v2c" %>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs font-medium text-sr-ink font-medium">SNMP Version</span>
              </label>
              <.input
                type="select"
                field={@snmp_credential_form[:version]}
                class={ui_field_class(size: "sm", class: "w-full")}
                options={[
                  {"SNMPv1", "v1"},
                  {"SNMPv2c", "v2c"},
                  {"SNMPv3", "v3"}
                ]}
              />
            </div>
          </div>

          <%= if snmp_version in ["v1", "v2c"] do %>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-xs font-medium text-sr-ink font-medium">Community</span>
              </label>
              <.input
                type="password"
                name="snmp[community]"
                value=""
                class={ui_field_class(size: "sm", class: "w-full")}
                placeholder={
                  if @device_snmp_credential,
                    do: "Leave blank to keep existing",
                    else: "e.g., public"
                }
                autocomplete="off"
              />
              <label class="flex items-center justify-between gap-2 py-0">
                <span class="text-xs text-sr-muted">
                  Credentials are encrypted at rest.
                </span>
              </label>
            </div>
          <% else %>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-xs font-medium text-sr-ink font-medium">Username</span>
                </label>
                <.input
                  type="text"
                  field={@snmp_credential_form[:username]}
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </div>
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-xs font-medium text-sr-ink font-medium">Security Level</span>
                </label>
                <.input
                  type="select"
                  field={@snmp_credential_form[:security_level]}
                  class={ui_field_class(size: "sm", class: "w-full")}
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
                  <span class="text-xs font-medium text-sr-ink font-medium">Auth Protocol</span>
                </label>
                <.input
                  type="select"
                  field={@snmp_credential_form[:auth_protocol]}
                  class={ui_field_class(size: "sm", class: "w-full")}
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
                  <span class="text-xs font-medium text-sr-ink font-medium">Auth Password</span>
                </label>
                <.input
                  type="password"
                  name="snmp[auth_password]"
                  value=""
                  class={ui_field_class(size: "sm", class: "w-full")}
                  placeholder={
                    if @device_snmp_credential,
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
                  <span class="text-xs font-medium text-sr-ink font-medium">Privacy Protocol</span>
                </label>
                <.input
                  type="select"
                  field={@snmp_credential_form[:priv_protocol]}
                  class={ui_field_class(size: "sm", class: "w-full")}
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
                  <span class="text-xs font-medium text-sr-ink font-medium">Privacy Password</span>
                </label>
                <.input
                  type="password"
                  name="snmp[priv_password]"
                  value=""
                  class={ui_field_class(size: "sm", class: "w-full")}
                  placeholder={
                    if @device_snmp_credential,
                      do: "Leave blank to keep existing",
                      else: "Privacy password"
                  }
                  autocomplete="off"
                />
              </div>
            </div>
          <% end %>

          <div class="flex items-center gap-2">
            <.ui_button type="submit" variant="outline" size="xs">
              Save SNMP Credentials
            </.ui_button>
            <span class="text-xs text-sr-muted">
              Overrides take precedence over profile credentials.
            </span>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  # Agent status comes from the ocsf_agents linkage resolved at load time
  # (DeviceStateData.tag_agent_device/2); the OCSF agent_list column is dead.
  defp agent_device?(row), do: DeviceStateData.agent?(row)
end
