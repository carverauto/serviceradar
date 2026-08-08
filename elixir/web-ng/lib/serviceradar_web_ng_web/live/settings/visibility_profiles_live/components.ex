defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Components do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.FormState

  alias ServiceRadarWebNGWeb.SRQL.Catalog

  attr(:profiles, :list, required: true)
  attr(:can_write, :boolean, default: false)
  attr(:can_delete, :boolean, default: false)

  def profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Visibility Profiles</div>
            <p class="text-xs text-sr-muted">
              {length(@profiles)} profile(s) configured
            </p>
          </div>
          <.link :if={@can_write} navigate={~p"/settings/networks/visibility-profiles/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr class="text-xs uppercase tracking-wide text-sr-muted">
              <th>Status</th>
              <th>Name</th>
              <th>Targeting</th>
              <th>Interfaces</th>
              <th>Sample</th>
              <th>Capabilities</th>
              <th>Retention</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="8" class="text-center text-sr-muted py-8">
                No visibility profiles configured.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-sr-subtle/40">
                <td>
                  <button
                    :if={@can_write}
                    phx-click="toggle_profile"
                    phx-value-id={profile.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                  <div :if={not @can_write} class="flex items-center gap-1.5">
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </div>
                </td>
                <td>
                  <.link
                    :if={@can_write}
                    navigate={~p"/settings/networks/visibility-profiles/#{profile.id}/edit"}
                    class="font-medium hover:text-sr-brand"
                  >
                    {profile.name}
                  </.link>
                  <span :if={not @can_write} class="font-medium">{profile.name}</span>
                  <p :if={profile.description} class="text-xs text-sr-muted truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs max-w-xs">
                  <%= if profile.target_query && profile.target_query != "" do %>
                    <code class="font-mono text-[11px] bg-sr-subtle/50 px-1.5 py-0.5 rounded truncate block max-w-[220px]">
                      {profile.target_query}
                    </code>
                  <% else %>
                    <span class="text-sr-muted">in:devices</span>
                  <% end %>
                </td>
                <td>
                  <div class="flex flex-wrap gap-1 max-w-[180px]">
                    <.ui_badge
                      :for={iface <- profile.capture_interfaces || []}
                      variant="ghost"
                      size="xs"
                    >
                      {iface}
                    </.ui_badge>
                    <span
                      :if={(profile.capture_interfaces || []) == []}
                      class="text-xs text-sr-muted"
                    >
                      none
                    </span>
                  </div>
                </td>
                <td class="font-mono text-xs">{profile.sample_interval_ms} ms</td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :if={fingerprint_enabled?(profile, "tcp")} variant="ghost" size="xs">
                      TCP
                    </.ui_badge>
                    <.ui_badge :if={fingerprint_enabled?(profile, "tls")} variant="ghost" size="xs">
                      TLS
                    </.ui_badge>
                    <.ui_badge :if={fingerprint_enabled?(profile, "http")} variant="ghost" size="xs">
                      HTTP
                    </.ui_badge>
                    <.ui_badge
                      :for={protocol <- dpi_protocols()}
                      :if={dpi_enabled?(profile, protocol)}
                      variant="info"
                      size="xs"
                    >
                      DPI {dpi_protocol_label(protocol)}
                    </.ui_badge>
                    <.ui_badge
                      :for={protocol <- flow_protocols()}
                      :if={flow_attribution_enabled?(profile, protocol)}
                      variant="success"
                      size="xs"
                    >
                      Flow {String.upcase(protocol)}
                    </.ui_badge>
                    <.ui_badge
                      :if={process_snapshot_enabled?(profile)}
                      variant="warning"
                      size="xs"
                    >
                      Snapshots {profile.process_snapshot_interval_s}s
                    </.ui_badge>
                  </div>
                </td>
                <td class="font-mono text-xs">{profile.retention_days}d</td>
                <td>
                  <div class="flex items-center gap-1">
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="preview_json"
                      phx-value-id={profile.id}
                      title="Preview config"
                    >
                      <.icon name="hero-code-bracket" class="size-3" />
                    </.ui_button>
                    <.link
                      :if={@can_write}
                      navigate={~p"/settings/networks/visibility-profiles/#{profile.id}/edit"}
                    >
                      <.ui_button variant="ghost" size="xs" title="Edit profile">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      :if={@can_delete}
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Delete this visibility profile?"
                      title="Delete profile"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  attr(:form, :map, required: true)
  attr(:errors, :list, default: [])
  attr(:show_form, :atom, required: true)
  attr(:selected_profile, :any, default: nil)
  attr(:target_device_count, :integer, default: nil)
  attr(:builder_open, :boolean, default: false)
  attr(:builder, :map, required: true)
  attr(:builder_sync, :boolean, default: true)

  def profile_form(assigns) do
    config = Catalog.entity("devices")

    assigns =
      assigns
      |> assign(:device_fields, device_filter_fields(config))
      |> assign(:dpi_protocol_options, Enum.map(dpi_protocols(), &{&1, dpi_protocol_label(&1)}))
      |> assign(:filter_ops, [
        {"contains", "contains"},
        {"equals", "equals"},
        {"not contains", "not_contains"},
        {"not equals", "not_equals"}
      ])

    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">
              {if @show_form == :new_profile,
                do: "New Visibility Profile",
                else: "Edit Visibility Profile"}
            </div>
            <p class="text-xs text-sr-muted">
              {target_count_label(@target_device_count)}
            </p>
          </div>
          <.link navigate={~p"/settings/networks/visibility-profiles"}>
            <.ui_button variant="ghost" size="sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.ui_button>
          </.link>
        </div>
      </:header>

      <form
        id="visibility-profile-form"
        phx-change="validate_profile"
        phx-submit="save_profile"
        class="space-y-6"
      >
        <div :if={@errors != []} class={ui_alert_class("error")}>
          <ul class="text-sm">
            <li :for={error <- @errors}>{error}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.text_input name="form[name]" label="Name" value={@form["name"]} required />
          <.number_input name="form[priority]" label="Priority" value={@form["priority"]} />
          <.text_input name="form[description]" label="Description" value={@form["description"]} />
          <.number_input
            name="form[sample_interval_ms]"
            label="Sample interval ms"
            value={@form["sample_interval_ms"]}
            min="0"
          />
          <.number_input
            name="form[retention_days]"
            label="Retention days"
            value={@form["retention_days"]}
            min="1"
          />
          <label class="flex cursor-pointer items-center justify-start gap-3">
            <input type="hidden" name="form[enabled]" value="false" />
            <input
              type="checkbox"
              name="form[enabled]"
              value="true"
              class={ui_toggle_class()}
              checked={truthy?(@form["enabled"])}
            />
            <span class="text-sm font-medium text-sr-ink">Enabled</span>
          </label>
        </div>

        <div class="rounded-lg border border-sr-line p-4 space-y-3">
          <div class="flex items-center justify-between">
            <div>
              <div class="text-sm font-semibold">Targeting</div>
              <p class="text-xs text-sr-muted">{target_count_label(@target_device_count)}</p>
            </div>
            <.ui_button
              type="button"
              variant={if @builder_open, do: "primary", else: "ghost"}
              size="sm"
              phx-click="builder_toggle"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4" /> Query Builder
            </.ui_button>
          </div>

          <textarea
            name="form[target_query]"
            class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-xs")}
            rows="3"
          >{@form["target_query"]}</textarea>

          <div :if={@builder_open} class="rounded-lg bg-sr-subtle/40 p-3 space-y-3">
            <div class="flex items-center justify-between">
              <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
                Device filters
              </div>
              <.ui_button :if={not @builder_sync} type="button" size="xs" phx-click="builder_apply">
                Apply
              </.ui_button>
            </div>
            <form id="visibility-builder-form" phx-change="builder_change" phx-debounce="200"></form>
            <%= for {filter, idx} <- Enum.with_index(@builder["filters"] || []) do %>
              <div class="flex flex-wrap items-center gap-2">
                <.query_builder_pill label="Filter">
                  <select
                    class={ui_field_class(size: "xs")}
                    name={"builder[filters][#{idx}][field]"}
                    form="visibility-builder-form"
                  >
                    <option
                      :for={field <- @device_fields}
                      value={field.name}
                      selected={filter["field"] == field.name}
                    >
                      {field.label}
                    </option>
                  </select>
                  <select
                    class={ui_field_class(size: "xs")}
                    name={"builder[filters][#{idx}][op]"}
                    form="visibility-builder-form"
                  >
                    <option
                      :for={{label, value} <- @filter_ops}
                      value={value}
                      selected={filter["op"] == value}
                    >
                      {label}
                    </option>
                  </select>
                  <input
                    class={ui_field_class(size: "xs", class: "w-44")}
                    name={"builder[filters][#{idx}][value]"}
                    form="visibility-builder-form"
                    value={filter["value"]}
                  />
                </.query_builder_pill>
                <.ui_button
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="builder_remove_filter"
                  phx-value-idx={idx}
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </.ui_button>
              </div>
            <% end %>
            <.ui_button type="button" variant="ghost" size="sm" phx-click="builder_add_filter">
              <.icon name="hero-plus" class="size-4" /> Filter
            </.ui_button>
          </div>
        </div>

        <div class="rounded-lg border border-sr-line p-4 space-y-3">
          <div class="text-sm font-semibold">Passive Fingerprinting</div>
          <label class="flex flex-col gap-1.5">
            <span class="text-xs font-medium text-sr-ink">Capture interfaces</span>
            <textarea
              name="form[capture_interfaces]"
              class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-xs")}
              rows="3"
              placeholder="eth0"
            >{@form["capture_interfaces"]}</textarea>
          </label>
          <div class="flex flex-wrap gap-4">
            <.fingerprint_toggle
              name="tcp"
              label="TCP"
              checked={truthy?(@form["fingerprint"]["tcp"])}
            />
            <.fingerprint_toggle
              name="tls"
              label="TLS"
              checked={truthy?(@form["fingerprint"]["tls"])}
            />
            <.fingerprint_toggle
              name="http"
              label="HTTP"
              checked={truthy?(@form["fingerprint"]["http"])}
            />
          </div>
        </div>

        <div class="rounded-lg border border-sr-line p-4 space-y-3">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div class="text-sm font-semibold">Deep Packet Inspection</div>
              <p class="text-xs text-sr-muted">
                Protocol detection only; payloads, URIs, and DNS names are not stored.
              </p>
            </div>
            <label class="flex cursor-pointer items-center justify-start gap-3 py-0">
              <input type="hidden" name="form[dpi][enabled]" value="false" />
              <input
                type="checkbox"
                name="form[dpi][enabled]"
                value="true"
                class={ui_toggle_class(size: "sm")}
                checked={truthy?(@form["dpi"]["enabled"])}
              />
              <span class="text-sm font-medium text-sr-ink">Enabled</span>
            </label>
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-2">
            <.dpi_toggle
              :for={{protocol, label} <- @dpi_protocol_options}
              name={protocol}
              label={label}
              checked={truthy?(@form["dpi"]["protocols"][protocol])}
            />
          </div>
        </div>

        <div class="rounded-lg border border-sr-line p-4">
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div class="space-y-3">
              <div>
                <div class="text-sm font-semibold">Flow Attribution</div>
                <p class="text-xs text-sr-muted">
                  Attach local process identity to observed connections.
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <.flow_attribution_toggle
                  :for={protocol <- flow_protocols()}
                  name={protocol}
                  label={String.upcase(protocol)}
                  checked={truthy?(@form["flow_attribution"][protocol])}
                />
              </div>
            </div>

            <div class="space-y-3">
              <div>
                <div class="text-sm font-semibold">Process Snapshots</div>
                <p class="text-xs text-sr-muted">
                  Periodically record local listening sockets with redacted process context.
                </p>
              </div>
              <.number_input
                name="form[process_snapshot_interval_s]"
                label="Snapshot interval seconds"
                value={@form["process_snapshot_interval_s"]}
                min="0"
              />
            </div>
          </div>
        </div>

        <div class="flex justify-end gap-2">
          <.link navigate={~p"/settings/networks/visibility-profiles"}>
            <.ui_button type="button" variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            <.icon name="hero-check" class="size-4" /> Save Profile
          </.ui_button>
        </div>
      </form>
    </.ui_panel>
    """
  end

  attr(:json_preview, :string, required: true)

  def json_preview_modal(assigns) do
    ~H"""
    <dialog
      id="components-modal-1"
      class="sr-ui-modal sr-ui-modal-open"
      phx-hook="DialogTopLayer"
      data-cancel="close_preview"
    >
      <div class="sr-ui-modal-box sr-ui-modal-box-md">
        <h3 class="font-bold text-lg mb-4">Compiled Visibility Config</h3>
        <pre class="bg-sr-subtle/50 p-4 rounded-lg text-xs font-mono overflow-x-auto max-h-96">{@json_preview}</pre>
        <div class="sr-ui-modal-action">
          <.ui_button phx-click="close_preview" size="sm" variant="neutral">Close</.ui_button>
        </div>
      </div>
    </dialog>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:checked, :boolean, default: false)

  defp fingerprint_toggle(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center justify-start gap-3">
      <input type="hidden" name={"form[fingerprint][#{@name}]"} value="false" />
      <input
        type="checkbox"
        name={"form[fingerprint][#{@name}]"}
        value="true"
        class={ui_checkbox_class()}
        checked={@checked}
      />
      <span class="text-sm font-medium text-sr-ink">{@label}</span>
    </label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:checked, :boolean, default: false)

  defp dpi_toggle(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center gap-2 justify-start gap-2 rounded-md border border-sr-line px-3 py-2 hover:bg-sr-subtle/40">
      <input type="hidden" name={"form[dpi][protocols][#{@name}]"} value="false" />
      <input
        type="checkbox"
        name={"form[dpi][protocols][#{@name}]"}
        value="true"
        class={ui_checkbox_class()}
        checked={@checked}
      />
      <span class="text-sm font-medium text-sr-ink">{@label}</span>
    </label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:checked, :boolean, default: false)

  defp flow_attribution_toggle(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center gap-2 justify-start gap-2 rounded-md border border-sr-line px-3 py-2 hover:bg-sr-subtle/40">
      <input type="hidden" name={"form[flow_attribution][#{@name}]"} value="false" />
      <input
        type="checkbox"
        name={"form[flow_attribution][#{@name}]"}
        value="true"
        class={ui_checkbox_class()}
        checked={@checked}
      />
      <span class="text-sm font-medium text-sr-ink">{@label}</span>
    </label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: "")
  attr(:required, :boolean, default: false)

  defp text_input(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs font-medium text-sr-ink">{@label}</span>
      <input
        type="text"
        name={@name}
        value={@value}
        required={@required}
        class={ui_field_class(size: "sm", class: "w-full")}
      />
    </label>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: "")
  attr(:min, :string, default: nil)

  defp number_input(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs font-medium text-sr-ink">{@label}</span>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        class={ui_field_class(size: "sm", class: "w-full")}
      />
    </label>
    """
  end

  defp device_filter_fields(%{filter_fields: fields}) when is_list(fields) do
    Enum.map(fields, fn field ->
      %{name: field, label: Phoenix.Naming.humanize(field)}
    end)
  end

  defp device_filter_fields(_), do: []

  defp dpi_protocol_label("http1"), do: "HTTP/1"
  defp dpi_protocol_label("http2"), do: "HTTP/2"
  defp dpi_protocol_label("tls"), do: "TLS"
  defp dpi_protocol_label("dns"), do: "DNS"
  defp dpi_protocol_label("ssh"), do: "SSH"
  defp dpi_protocol_label("ftp"), do: "FTP"
  defp dpi_protocol_label("quic"), do: "QUIC"
  defp dpi_protocol_label("mqtt"), do: "MQTT"
  defp dpi_protocol_label("bittorrent"), do: "BitTorrent"
  defp dpi_protocol_label(protocol), do: Phoenix.Naming.humanize(protocol)
end
