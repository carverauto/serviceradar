defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.FormComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents,
    only: [group_last_run_at: 1]

  import ServiceRadarWebNGWeb.Settings.NetworksLive.AgentPickerComponents

  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  # Group Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :profiles, :list, required: true
  attr :agent_picker, :any, required: true
  attr :agent_picker_open, :boolean, default: false
  attr :agent_picker_selected_rows, :list, default: []
  attr :agent_picker_summary_agent, :any, default: nil
  attr :target_device_count, :integer, default: nil
  attr :builder_open, :boolean, default: false
  attr :builder_sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def group_form(assigns) do
    assigns = assign(assigns, :config, Catalog.entity("devices"))

    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_group, do: "New Sweep Group", else: "Edit Sweep Group"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <form id="sweep-group-builder-form" phx-change="builder_change" phx-debounce="200"></form>

      <.form
        for={@form}
        id="sweep-group-form"
        phx-submit="save_group"
        phx-change="validate_group"
        class="space-y-6"
      >
        <!-- Basic Info Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-sr-ink/90 uppercase tracking-wide">
            Basic Information
          </h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Name</span>
              </label>
              <.input
                type="text"
                field={@form[:name]}
                class={ui_field_class(class: "w-full")}
                required
              />
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Partition</span>
              </label>
              <.input
                type="text"
                field={@form[:partition]}
                class={ui_field_class(class: "w-full")}
                placeholder="default"
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
              rows="2"
            />
          </div>
        </div>

        <!-- Schedule Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-sr-ink/90 uppercase tracking-wide">Schedule</h3>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Scan Interval</span>
              </label>
              <.input
                type="select"
                field={@form[:interval]}
                class={ui_field_class(class: "w-full")}
                options={[
                  {"5 minutes", "5m"},
                  {"15 minutes", "15m"},
                  {"30 minutes", "30m"},
                  {"1 hour", "1h"},
                  {"2 hours", "2h"},
                  {"6 hours", "6h"},
                  {"12 hours", "12h"},
                  {"24 hours", "24h"}
                ]}
              />
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Scanner Profile</span>
              </label>
              <.input
                type="select"
                field={@form[:profile_id]}
                class={ui_field_class(class: "w-full")}
                options={[{"Default settings", ""} | Enum.map(@profiles, &{&1.name, &1.id})]}
              />
            </div>
          </div>

          <.agent_assignment_fields
            state={@agent_picker}
            summary_agent={@agent_picker_summary_agent}
          />
        </div>

        <!-- Target Criteria Section -->
        <div class="space-y-4">
          <div class="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h3 class="text-sm font-semibold text-sr-ink/90 uppercase tracking-wide">
                Device Targeting
              </h3>
              <p class="text-xs text-sr-muted">
                SRQL query to select devices for this sweep group.
              </p>
            </div>
          </div>

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
                  placeholder="e.g., tags.env:prod hostname:%db%"
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
                SRQL filters to match devices. Examples: <code class="bg-sr-subtle px-1 rounded">tags.environment:production</code>, <code class="bg-sr-subtle px-1 rounded">hostname:%prod%</code>,
                <code class="bg-sr-subtle px-1 rounded">type:Server</code>
              </span>
            </label>
          </div>

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

            <div class="flex flex-col gap-4">
              <div class="flex flex-col gap-3">
                <div class="text-xs text-sr-muted font-medium">
                  Match devices where:
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
                          form="sweep-group-builder-form"
                          class="w-40 placeholder:text-sr-muted"
                        />
                      <% else %>
                        <.ui_inline_select
                          name={"builder[filters][#{idx}][field]"}
                          form="sweep-group-builder-form"
                        >
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
                        form="sweep-group-builder-form"
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
                        form="sweep-group-builder-form"
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
          </div>

          <div :if={@target_device_count != nil} class="flex items-center gap-2">
            <.icon name="hero-device-phone-mobile" class="size-4 text-sr-muted" />
            <span class="text-sm">
              <span class="font-semibold">{@target_device_count}</span>
              <span class="text-sr-muted">device(s) match this query</span>
            </span>
          </div>
        </div>

        <!-- Static Targets Section -->
        <div class="space-y-4">
          <h3 class="text-sm font-semibold text-sr-ink/90 uppercase tracking-wide">
            Static Targets
          </h3>
          <p class="text-xs text-sr-muted">
            IPs, CIDRs, or ranges to always include, regardless of tags.
          </p>
          <.input
            type="textarea"
            field={@form[:static_targets]}
            value={format_static_targets(@form[:static_targets].value)}
            class={ui_field_class(mono: true, class: "w-full min-h-24 py-2.5 text-sm")}
            rows="3"
            placeholder="10.0.1.0/24&#10;192.168.1.0/24&#10;10.0.0.10-10.0.0.50"
          />
        </div>

        <!-- Enable Toggle -->
        <div class="flex items-center gap-2 pt-2">
          <.input type="checkbox" field={@form[:enabled]} class={ui_checkbox_class()} />
          <label class="text-sm font-medium text-sr-ink">Enable this sweep group</label>
        </div>

        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <.input
              type="checkbox"
              field={@form[:emit_availability_events]}
              class={ui_checkbox_class()}
            />
            <label class="text-sm font-medium text-sr-ink">
              Emit availability events
            </label>
          </div>
          <p class="text-xs text-sr-muted pl-7">
            When a sweep flips a device to unreachable, write a
            <code class="bg-sr-subtle px-1 rounded">device.unavailable</code>
            event. Recovery writes <code class="bg-sr-subtle px-1 rounded">device.available</code>
            and clears the matching alert.
          </p>
        </div>

        <!-- Actions -->
        <div class="flex justify-end gap-2 pt-4 border-t border-sr-line">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Sweep Group</.ui_button>
        </div>
      </.form>

      <.agent_picker_modal
        state={@agent_picker}
        open={@agent_picker_open}
        selected_rows={@agent_picker_selected_rows}
      />
    </.ui_panel>
    """
  end

  # Profile Form
  attr :form, :any, required: true
  attr :show_form, :atom, required: true
  attr :can_enable_banner_grab, :boolean, default: false
  attr :banner_preview_device_count, :any, default: nil
  attr :banner_grab_draft, :any, default: nil

  def profile_form(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div class="text-sm font-semibold">
            {if @show_form == :new_profile, do: "New Scanner Profile", else: "Edit Scanner Profile"}
          </div>
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">Cancel</.ui_button>
          </.link>
        </div>
      </:header>

      <.form
        for={@form}
        id="scanner-profile-form"
        phx-submit="save_profile"
        phx-change="validate_profile"
        class="space-y-4"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Name</span>
            </label>
            <.input type="text" field={@form[:name]} class={ui_field_class(class: "w-full")} required />
          </div>
          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Timeout</span>
            </label>
            <.input
              type="select"
              field={@form[:timeout]}
              class={ui_field_class(class: "w-full")}
              options={[
                {"1 second", "1s"},
                {"3 seconds", "3s"},
                {"5 seconds", "5s"},
                {"10 seconds", "10s"},
                {"30 seconds", "30s"}
              ]}
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
            rows="2"
          />
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Ports (comma-separated)</span>
            </label>
            <.input
              type="text"
              field={@form[:ports]}
              value={format_ports_input(@form[:ports].value)}
              class={ui_field_class(mono: true, class: "w-full")}
              placeholder="22, 80, 443, 3389, 8080"
            />
          </div>
          <div>
            <label class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-sr-ink">Concurrency</span>
            </label>
            <.input
              type="number"
              field={@form[:concurrency]}
              class={ui_field_class(class: "w-full")}
              min="1"
              max="500"
            />
          </div>
        </div>

        <div>
          <label class="flex items-center justify-between gap-2">
            <span class="text-sm font-medium text-sr-ink">Sweep Modes</span>
          </label>
          <% selected_modes = Enum.map(@form[:sweep_modes].value || [], &to_string/1) %>
          <div class="flex flex-wrap gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="form[sweep_modes][]"
                value="icmp"
                class={ui_checkbox_class()}
                checked={Enum.member?(selected_modes, "icmp")}
              />
              <span>ICMP (Ping)</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="form[sweep_modes][]"
                value="tcp"
                class={ui_checkbox_class()}
                checked={Enum.member?(selected_modes, "tcp")}
              />
              <span>TCP</span>
            </label>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <.input type="checkbox" field={@form[:enabled]} class={ui_checkbox_class()} />
          <label class="text-sm font-medium text-sr-ink">Enabled</label>
        </div>

        <% banner_grab = @banner_grab_draft || banner_grab_form_value(@form) %>
        <% banner_preview = banner_grab_preview(banner_grab, @banner_preview_device_count) %>
        <div class="rounded-lg border border-sr-line p-4 space-y-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <div class="text-sm font-semibold">Banner grab</div>
              <p class="text-xs text-sr-muted">
                Active TCP connects for license-clean banner fingerprint matching.
              </p>
            </div>
            <%= if @can_enable_banner_grab do %>
              <label class="flex cursor-pointer items-center justify-start gap-3 py-0">
                <input type="hidden" name="form[banner_grab][enabled]" value="false" />
                <input
                  type="checkbox"
                  name="form[banner_grab][enabled]"
                  value="true"
                  class={ui_toggle_class(size: "sm")}
                  checked={truthy?(banner_grab_value(banner_grab, "enabled", false))}
                />
                <span class="text-sm font-medium text-sr-ink">Enabled</span>
              </label>
            <% else %>
              <.ui_badge variant="ghost" size="sm">Restricted</.ui_badge>
            <% end %>
          </div>

          <%= if @can_enable_banner_grab do %>
            <input type="hidden" name="form[banner_grab][protocols][]" value="" />
            <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
              <div class="lg:col-span-2 space-y-3">
                <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
                  Protocols and ports
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3">
                  <%= for {protocol, label} <- banner_grab_protocol_options() do %>
                    <div class="rounded-md border border-sr-line p-3 space-y-2">
                      <label class="flex items-center gap-2 cursor-pointer">
                        <input
                          type="checkbox"
                          name="form[banner_grab][protocols][]"
                          value={protocol}
                          class={ui_checkbox_class()}
                          checked={Enum.member?(banner_grab_protocols(banner_grab), protocol)}
                        />
                        <span class="text-sm font-medium">{label}</span>
                      </label>
                      <input
                        type="text"
                        name={"form[banner_grab][ports][#{protocol}]"}
                        value={banner_grab_ports_input(banner_grab, protocol)}
                        class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                        placeholder={banner_grab_default_ports(protocol)}
                      />
                    </div>
                  <% end %>
                </div>
              </div>

              <div class="rounded-md border border-sr-line bg-sr-surface/60 p-3 space-y-3">
                <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
                  Outbound traffic preview
                </div>
                <div class="grid grid-cols-2 gap-3 text-sm">
                  <div>
                    <div class="text-xs text-sr-muted">Inventory</div>
                    <div class="font-semibold">{banner_preview.device_count}</div>
                  </div>
                  <div>
                    <div class="text-xs text-sr-muted">Ports</div>
                    <div class="font-semibold">{banner_preview.port_count}</div>
                  </div>
                  <div>
                    <div class="text-xs text-sr-muted">Connects</div>
                    <div class="font-semibold">{banner_preview.connects}</div>
                  </div>
                  <div>
                    <div class="text-xs text-sr-muted">Elapsed</div>
                    <div class="font-semibold">{banner_preview.elapsed}</div>
                  </div>
                </div>
              </div>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
              <.banner_number_input
                name="connect_timeout_ms"
                label="Connect timeout ms"
                value={banner_grab_value(banner_grab, "connect_timeout_ms", 2_000)}
                min="1"
                max="30000"
              />
              <.banner_number_input
                name="read_timeout_ms"
                label="Read timeout ms"
                value={banner_grab_value(banner_grab, "read_timeout_ms", 2_000)}
                min="1"
                max="30000"
              />
              <.banner_number_input
                name="max_banner_bytes"
                label="Max banner bytes"
                value={banner_grab_value(banner_grab, "max_banner_bytes", 1_024)}
                min="1"
                max="65536"
              />
              <.banner_number_input
                name="max_concurrency_per_host"
                label="Per-host concurrency"
                value={banner_grab_value(banner_grab, "max_concurrency_per_host", 4)}
                min="1"
                max="4096"
              />
              <.banner_number_input
                name="max_global_concurrency"
                label="Global concurrency"
                value={banner_grab_value(banner_grab, "max_global_concurrency", 256)}
                min="1"
                max="4096"
              />
              <.banner_number_input
                name="max_probe_rate_per_second"
                label="Max probe rate"
                value={banner_grab_value(banner_grab, "max_probe_rate_per_second", 0)}
                min="0"
                max="50000"
              />
              <.banner_number_input
                name="max_candidate_queue"
                label="Candidate queue"
                value={banner_grab_value(banner_grab, "max_candidate_queue", 8_192)}
                min="1"
                max="1000000"
              />
              <.banner_number_input
                name="match_batch_size"
                label="Match batch size"
                value={banner_grab_value(banner_grab, "match_batch_size", 256)}
                min="1"
                max="4096"
              />
              <.banner_number_input
                name="match_batch_max_bytes"
                label="Match batch bytes"
                value={banner_grab_value(banner_grab, "match_batch_max_bytes", 1_048_576)}
                min="1"
                max="4194304"
              />
              <.banner_number_input
                name="min_reprobe_interval_s"
                label="Min re-probe interval s"
                value={banner_grab_value(banner_grab, "min_reprobe_interval_s", 86_400)}
                min="0"
              />
              <.banner_number_input
                name="per_host_rate_limit_ms"
                label="Per-host rate limit ms"
                value={banner_grab_value(banner_grab, "per_host_rate_limit_ms", 100)}
                min="0"
              />
            </div>
          <% else %>
            <p class="text-xs text-sr-muted">
              Requires the networks.sweeps.banner_grab permission.
            </p>
          <% end %>
        </div>

        <div class="flex justify-end gap-2 pt-4">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">Save Profile</.ui_button>
        </div>
      </.form>
    </.ui_panel>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :min, :string, default: nil
  attr :max, :string, default: nil

  def banner_number_input(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-xs font-medium text-sr-ink">{@label}</span>
      <input
        type="number"
        name={"form[banner_grab][#{@name}]"}
        value={@value}
        min={@min}
        max={@max}
        class={ui_field_class(size: "sm", class: "w-full")}
      />
    </label>
    """
  end

  # Group Detail View
  attr :group, :map, required: true
  attr :summary_agents, :map, default: %{}
  attr :timezone, :string, required: true

  def group_detail(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/settings/networks"}>
            <.ui_button variant="ghost" size="sm">
              <.icon name="hero-arrow-left" class="size-4" />
            </.ui_button>
          </.link>
          <div>
            <h2 class="text-xl font-semibold">{@group.name}</h2>
            <p :if={@group.description} class="text-sm text-sr-muted">{@group.description}</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/settings/networks/groups/#{@group.id}/edit"}>
            <.ui_button variant="outline" size="sm">
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.ui_button>
          </.link>
        </div>
      </div>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Configuration</div>
        </:header>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <div class="text-xs text-sr-muted uppercase">Status</div>
            <div class="flex items-center gap-1.5 mt-1">
              <span class={"size-2 rounded-full #{if @group.enabled, do: "bg-success", else: "bg-sr-muted/30"}"}></span>
              <span>{if @group.enabled, do: "Enabled", else: "Disabled"}</span>
            </div>
          </div>
          <div>
            <div class="text-xs text-sr-muted uppercase">Schedule</div>
            <div class="mt-1 font-mono">{format_schedule(@group)}</div>
          </div>
          <div>
            <div class="text-xs text-sr-muted uppercase">Partition</div>
            <div class="mt-1">{@group.partition}</div>
          </div>
          <div>
            <div class="text-xs text-sr-muted uppercase">Scanner agents</div>
            <div id="sweep-group-assignment-summary" class="mt-1">
              {agent_assignment_summary(@group.agent_ids, @summary_agents)}
            </div>
          </div>
          <div>
            <div class="text-xs text-sr-muted uppercase">Last Run</div>
            <div class="mt-1">
              <.user_time
                id={"settings-sweep-group-#{@group.id}-detail-last-run-at"}
                value={group_last_run_at(@group)}
                timezone={@timezone}
                style={:compact}
                fallback="Never"
              />
            </div>
          </div>
        </div>
      </.ui_panel>

      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Targets</div>
        </:header>

        <div class="space-y-2">
          <div :if={@group.static_targets != []} class="space-y-1">
            <div class="text-xs text-sr-muted uppercase">Static Targets</div>
            <div class="flex flex-wrap gap-2">
              <%= for target <- (@group.static_targets || []) do %>
                <.ui_badge variant="ghost" size="sm" class="font-mono">{target}</.ui_badge>
              <% end %>
            </div>
          </div>
          <div :if={@group.target_query not in [nil, ""]} class="space-y-2">
            <div class="text-xs text-sr-muted uppercase">Target Query (SRQL)</div>
            <div class="font-mono text-sm text-sr-ink/90 break-words">
              {@group.target_query}
            </div>
          </div>
          <div :if={@group.static_targets == [] and @group.target_query in [nil, ""]}>
            <p class="text-sr-muted">No targets configured.</p>
          </div>
          <div class="pt-2 text-xs text-sr-muted">
            Availability events:
            <span class="text-sr-ink">
              {if(@group.emit_availability_events, do: "on", else: "off")}
            </span>
          </div>
        </div>
      </.ui_panel>
    </div>
    """
  end

  def format_schedule(group) do
    case group.schedule_type do
      :cron -> group.cron_expression || "—"
      _ -> "Every #{group.interval}"
    end
  end

  def format_ports_input(nil), do: ""
  def format_ports_input(""), do: ""

  def format_ports_input(ports) when is_list(ports) do
    Enum.map_join(ports, ", ", &to_string/1)
  end

  def format_ports_input(value) when is_binary(value), do: value

  def format_static_targets(targets) when is_list(targets) do
    Enum.join(targets, "\n")
  end

  def format_static_targets(targets) when is_binary(targets), do: targets
  def format_static_targets(_), do: ""

  def banner_grab_form_value(form) do
    form
    |> Phoenix.HTML.Form.input_value(:banner_grab)
    |> banner_grab_to_map()
  end

  def banner_grab_to_map(%_{} = banner_grab) do
    banner_grab
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
  end

  def banner_grab_to_map(%{} = banner_grab), do: banner_grab
  def banner_grab_to_map(_banner_grab), do: BannerGrab.default_input()

  def banner_grab_value(banner_grab, key, default) do
    Map.get(banner_grab, key, Map.get(banner_grab, banner_key_atom(key), default))
  end

  def banner_key_atom("enabled"), do: :enabled
  def banner_key_atom("protocols"), do: :protocols
  def banner_key_atom("ports"), do: :ports
  def banner_key_atom("connect_timeout_ms"), do: :connect_timeout_ms
  def banner_key_atom("read_timeout_ms"), do: :read_timeout_ms
  def banner_key_atom("max_banner_bytes"), do: :max_banner_bytes
  def banner_key_atom("max_concurrency_per_host"), do: :max_concurrency_per_host
  def banner_key_atom("max_global_concurrency"), do: :max_global_concurrency
  def banner_key_atom("max_probe_rate_per_second"), do: :max_probe_rate_per_second
  def banner_key_atom("max_candidate_queue"), do: :max_candidate_queue
  def banner_key_atom("match_batch_size"), do: :match_batch_size
  def banner_key_atom("match_batch_max_bytes"), do: :match_batch_max_bytes
  def banner_key_atom("min_reprobe_interval_s"), do: :min_reprobe_interval_s
  def banner_key_atom("per_host_rate_limit_ms"), do: :per_host_rate_limit_ms
  def banner_key_atom(_other), do: nil

  def banner_grab_protocols(banner_grab) do
    banner_grab
    |> banner_grab_value("protocols", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  def banner_grab_ports_input(banner_grab, protocol) do
    banner_grab
    |> banner_grab_ports(protocol)
    |> Enum.map_join(", ", &to_string/1)
  end

  def banner_grab_ports(banner_grab, protocol) do
    ports = banner_grab_value(banner_grab, "ports", %{})

    case Map.get(ports, protocol) || Map.get(ports, protocol_atom(protocol)) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  def protocol_atom("ssh"), do: :ssh
  def protocol_atom("http"), do: :http
  def protocol_atom("smb"), do: :smb
  def protocol_atom("ftp"), do: :ftp
  def protocol_atom("telnet"), do: :telnet
  def protocol_atom("smtp"), do: :smtp
  def protocol_atom("ntp"), do: :ntp
  def protocol_atom("dns"), do: :dns
  def protocol_atom("rdp"), do: :rdp
  def protocol_atom(_other), do: nil

  def banner_grab_protocol_options do
    [
      {"ssh", "SSH"},
      {"http", "HTTP"},
      {"smb", "SMB"},
      {"ftp", "FTP"},
      {"telnet", "Telnet"},
      {"smtp", "SMTP"},
      {"ntp", "NTP"},
      {"dns", "DNS"},
      {"rdp", "RDP"}
    ]
  end

  def banner_grab_default_ports("ssh"), do: "22"
  def banner_grab_default_ports("http"), do: "80, 8080, 8000, 8888"
  def banner_grab_default_ports("smb"), do: "139, 445"
  def banner_grab_default_ports("ftp"), do: "21"
  def banner_grab_default_ports("telnet"), do: "23"
  def banner_grab_default_ports("smtp"), do: "25, 587"
  def banner_grab_default_ports("ntp"), do: "123"
  def banner_grab_default_ports("dns"), do: "53"
  def banner_grab_default_ports("rdp"), do: "3389"

  def banner_grab_preview(banner_grab, device_count) do
    device_count = device_count || 0

    port_count =
      banner_grab
      |> banner_grab_protocols()
      |> Enum.flat_map(&banner_grab_ports(banner_grab, &1))
      |> Enum.uniq()
      |> length()

    connects = device_count * port_count
    rate = banner_grab_value(banner_grab, "max_probe_rate_per_second", 0)
    concurrency = max(banner_grab_value(banner_grab, "max_global_concurrency", 256), 1)
    timeout_ms = banner_grab_value(banner_grab, "connect_timeout_ms", 2_000)
    read_ms = banner_grab_value(banner_grab, "read_timeout_ms", 2_000)

    elapsed_seconds =
      cond do
        connects == 0 -> 0
        is_integer(rate) and rate > 0 -> ceil(connects / rate)
        true -> ceil(connects / concurrency * ((timeout_ms + read_ms) / 1_000))
      end

    %{
      device_count: format_count(device_count),
      port_count: format_count(port_count),
      connects: format_count(connects),
      elapsed: format_duration_seconds(elapsed_seconds)
    }
  end

  def format_count(value) when is_integer(value), do: :erlang.integer_to_binary(value)
  def format_count(_value), do: "0"

  def format_duration_seconds(seconds) when seconds <= 0, do: "0s"
  def format_duration_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  def format_duration_seconds(seconds) when seconds < 3_600 do
    "#{ceil(seconds / 60)}m"
  end

  def format_duration_seconds(seconds), do: "#{ceil(seconds / 3_600)}h"

  def truthy?(true), do: true
  def truthy?("true"), do: true
  def truthy?("on"), do: true
  def truthy?(1), do: true
  def truthy?(_value), do: false

  def agent_display_name(agent) do
    cond do
      agent.name && agent.name != "" -> agent.name
      agent.uid && agent.uid != "" -> agent.uid
      true -> "Agent #{agent.uid}"
    end
  end

  def agent_assignment_summary(agent_ids, summary_agents \\ %{}) do
    case Enum.filter(agent_ids || [], &is_binary/1) do
      [] ->
        "All agents"

      [uid] ->
        case Map.get(summary_agents, uid) do
          nil -> "#{uid} (Unavailable)"
          agent -> agent_display_name(agent)
        end

      ids ->
        "#{length(ids)} selected"
    end
  end
end
