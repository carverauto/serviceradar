defmodule ServiceRadarWebNGWeb.Settings.NotificationsLive.Components do
  @moduledoc """
  The rendered surface of `/settings/notifications`.

  Function components only - the LiveView owns state and events, these own
  markup. Everything is built from the project-owned `sr-*` Tailwind tokens and
  `ServiceRadarWebNGWeb.UIComponents`; daisyUI has been removed from the asset
  pipeline, so a `btn`, `card`, `badge`, `modal`, or `menu` class here would
  render unstyled.

  Two rules hold throughout and are worth stating because breaking either is
  silent:

  * **Nothing operator- or provider-supplied is rendered through `raw/1`.** Alert
    titles, provider error strings, and rendered notification bodies are
    untrusted; they are interpolated as text and escaped by the template.
  * **Colour is never the only signal.** Every health, state, and silence badge
    carries a text label, so the state survives a screen reader and a monochrome
    display.
  """

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Observability.SignalDisplayComponents, only: [signal_display_widget: 1]

  alias ServiceRadarWebNGWeb.PluginConfigForm
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Contracts
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.DeliveryFilters
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.EdgeRouteSafety
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Predicate
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.Presentation
  alias ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUpload

  # --- shared ---------------------------------------------------------------

  attr :label, :string, required: true
  attr :variant, :string, default: "ghost"
  attr :hint, :string, default: nil

  @doc "A state badge whose meaning is carried by its text, not by its colour."
  def state_badge(assigns) do
    ~H"""
    <.ui_badge variant={@variant} size="xs" title={@hint}>{@label}</.ui_badge>
    """
  end

  attr :message, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <p class="px-1 py-6 text-center text-sm text-sr-muted">{@message}</p>
    """
  end

  attr :loading, :boolean, default: false

  def loading_skeleton(assigns) do
    ~H"""
    <div :if={@loading} class="space-y-3" aria-busy="true" aria-live="polite">
      <span class="sr-only">Loading notification settings</span>
      <div :for={_row <- 1..4} class="h-10 animate-pulse rounded-sr-control bg-sr-subtle"></div>
    </div>
    """
  end

  attr :confirmation, :map, default: nil

  @doc """
  The confirmation dialog every destructive action goes through.

  Disable channel, disable provider, and cancel silence are high impact and
  irreversible from the operator's point of view, so each names the object and
  states the consequence before it runs.
  """
  def confirmation_dialog(assigns) do
    ~H"""
    <.ui_modal
      :if={@confirmation}
      id="notifications-confirm"
      size="form"
      on_cancel={JS.push("dismiss_confirmation")}
    >
      <:title>{@confirmation.title}</:title>
      <p class="text-sm text-sr-ink/80">{@confirmation.message}</p>
      <ul
        :if={@confirmation[:items] not in [nil, []]}
        class="mt-2 list-disc space-y-1 pl-5 text-sm text-sr-ink/80"
      >
        <li :for={item <- @confirmation.items}>{item}</li>
      </ul>
      <:actions>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="dismiss_confirmation">
          Cancel
        </.ui_button>
        <.ui_button
          type="button"
          size="sm"
          variant="danger"
          phx-click={@confirmation.event}
          phx-value-id={@confirmation.id}
          phx-value-version={@confirmation[:version]}
        >
          {@confirmation.confirm_label}
        </.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  # --- channels -------------------------------------------------------------

  attr :streams, :any, required: true
  attr :can_manage, :boolean, default: false
  attr :can_test, :boolean, default: false
  attr :channel_form, :map, default: nil
  attr :providers, :list, default: []
  attr :channel_index, :map, default: %{}
  attr :test_result, :map, default: nil
  attr :loading, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def channels_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Channels</div>
            <p class="text-xs text-sr-muted">
              A channel is one configured destination. Retries keep a delivery pending until
              max attempts is exhausted; only then does it become terminally failed and, if a
              fallback is set and fail-closed is off, fail over one hop.
            </p>
          </div>
          <.ui_button :if={@can_manage} size="sm" variant="primary" phx-click="new_channel">
            <.icon name="hero-plus" class="size-4" /> New channel
          </.ui_button>
        </:header>

        <.loading_skeleton loading={@loading} />

        <div :if={not @loading} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm", class: "w-full")}>
            <thead>
              <tr>
                <th scope="col">Name</th>
                <th scope="col">Provider</th>
                <th scope="col">Route</th>
                <th scope="col">Health</th>
                <th scope="col">Limits</th>
                <th scope="col">Failover</th>
                <th scope="col" class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody id="notification-channels" phx-update="stream">
              <tr :for={{dom_id, channel} <- @streams.channels} id={dom_id}>
                <td>
                  <div class="font-medium text-sr-ink">{channel.name}</div>
                  <div :if={channel.description} class="text-xs text-sr-muted">
                    {Presentation.truncate(channel.description, 80)}
                  </div>
                  <.state_badge
                    label={if channel.enabled, do: "Enabled", else: "Disabled"}
                    variant={if channel.enabled, do: "success", else: "ghost"}
                  />
                </td>
                <td>
                  <div>{provider_name(channel)}</div>
                  <div class="text-xs text-sr-muted">
                    {Presentation.provider_type_label(provider_field(channel, :provider_type))}
                  </div>
                </td>
                <td>
                  <div>{Presentation.execution_route_label(channel.execution_route)}</div>
                  <div :if={channel.agent_uid} class="text-xs text-sr-muted">
                    agent {channel.agent_uid}
                  </div>
                  <div :if={channel.partition_id} class="text-xs text-sr-muted">
                    partition {channel.partition_id}
                  </div>
                </td>
                <td>
                  <.state_badge
                    label={Presentation.channel_health_label(channel.health)}
                    variant={Presentation.channel_health_variant(channel.health)}
                  />
                  <div class="text-xs text-sr-muted">
                    ok
                    <.user_time
                      id={"notification-channel-#{channel.id}-last-success-at"}
                      value={channel.last_success_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <div class="text-xs text-sr-muted">
                    fail
                    <.user_time
                      id={"notification-channel-#{channel.id}-last-failure-at"}
                      value={channel.last_failure_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <details :if={channel.last_error} class="mt-1">
                    <summary class="cursor-pointer text-xs text-sr-brand">Last error</summary>
                    <p class="mt-1 max-w-xs break-words text-xs text-sr-muted">
                      {Presentation.truncate(channel.last_error, 300)}
                    </p>
                    <.contract_view
                      id={"channel-#{channel.id}-health-contract"}
                      view={Contracts.channel_health_view(channel, channel_provider(channel))}
                      class="mt-2 max-w-xs"
                      timezone={@timezone}
                    />
                  </details>
                </td>
                <td class="text-xs text-sr-muted">
                  <div>max attempts {channel.max_attempts}</div>
                  <div>rate {channel.rate_limit_per_minute || "unlimited"}/min</div>
                </td>
                <td class="text-xs text-sr-muted">
                  <div>{fallback_label(channel, @channel_index)}</div>
                  <div :if={channel.fail_closed}>fail closed: no failover</div>
                  <.channel_failover_badge advisory={
                    EdgeRouteSafety.channel_advisory(channel, @channel_index)
                  } />
                </td>
                <td class="text-right">
                  <div class="inline-flex gap-1">
                    <.ui_button
                      :if={@can_manage}
                      size="xs"
                      variant="ghost"
                      phx-click="edit_channel"
                      phx-value-id={channel.id}
                    >
                      Edit
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and channel.enabled}
                      size="xs"
                      variant="ghost"
                      phx-click="confirm_disable_channel"
                      phx-value-id={channel.id}
                    >
                      Disable
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and not channel.enabled}
                      size="xs"
                      variant="ghost"
                      phx-click="enable_channel"
                      phx-value-id={channel.id}
                    >
                      Enable
                    </.ui_button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.ui_panel>

      <.channel_editor
        :if={@channel_form}
        form={@channel_form}
        providers={@providers}
        channel_index={@channel_index}
        can_test={@can_test}
        test_result={@test_result}
      />
    </div>
    """
  end

  attr :form, :map, required: true
  attr :providers, :list, default: []
  attr :channel_index, :map, default: %{}
  attr :can_test, :boolean, default: false
  attr :test_result, :map, default: nil

  def channel_editor(assigns) do
    assigns =
      assigns
      |> assign(:provider, assigns.form[:provider])
      |> assign(:config_contract, Contracts.config_contract(assigns.form[:provider]))
      |> assign(:warnings, assigns.form[:warnings] || [])
      |> assign(:mailer_warning, assigns.form[:mailer_warning])

    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            {if @form.mode == :new, do: "New channel", else: "Edit channel"}
          </div>
          <p class="text-xs text-sr-muted">
            The configuration form is rendered from the provider's own config schema, so a new
            provider needs no web-ng change. Secret fields never show a stored value.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_channel_form">
          Close
        </.ui_button>
      </:header>

      <form phx-change="validate_channel" phx-submit="save_channel" class="space-y-4">
        <div :if={@warnings != []} class={ui_alert_class(variant: "warning")}>
          <div>
            <div class="font-medium">Check this configuration</div>
            <ul class="mt-1 list-disc space-y-1 pl-5">
              <li :for={warning <- @warnings}>{warning}</li>
            </ul>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Name</span>
            <input
              type="text"
              name="channel[name]"
              value={@form.params["name"]}
              required
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Description</span>
            <input
              type="text"
              name="channel[description]"
              value={@form.params["description"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>

          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Provider</span>
            <select
              name="channel[provider_id]"
              class={ui_field_class(class: "w-full")}
              disabled={@form.mode != :new}
            >
              <option value="">Select a provider</option>
              <option
                :for={provider <- @providers}
                value={provider.id}
                selected={to_string(provider.id) == @form.params["provider_id"]}
              >
                {provider.display_name} ({provider.provider_key})
              </option>
            </select>
            <span class="text-xs text-sr-muted">
              A provider cannot be swapped on a saved channel: the stored configuration is shaped
              by the provider's schema. Rebinding a destination is a new channel.
            </span>
          </label>

          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Execution route</span>
            <select name="channel[execution_route]" class={ui_field_class(class: "w-full")}>
              <option
                :for={{label, value} <- Presentation.route_options_for(supported_routes(@provider))}
                value={value}
                selected={value == @form.params["execution_route"]}
              >
                {label}
              </option>
            </select>
            <span class="text-xs text-sr-muted">
              Control plane egresses from the platform and is the recommended default. The channel
              partition is bound server-side from the agent's mTLS session and is never editable.
            </span>
          </label>

          <label :if={@form.params["execution_route"] == "edge_agent"} class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Agent UID</span>
            <input
              type="text"
              name="channel[agent_uid]"
              value={@form.params["agent_uid"]}
              class={ui_field_class(class: "w-full")}
            />
            <span class="text-xs text-sr-muted">Required when the route is edge agent.</span>
          </label>

          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Max attempts</span>
            <input
              type="number"
              min="1"
              max="20"
              name="channel[max_attempts]"
              value={@form.params["max_attempts"]}
              class={ui_field_class(class: "w-full")}
            />
            <span class="text-xs text-sr-muted">
              Provider default {provider_default_attempts(@provider)}. A delivery stays pending
              with a next attempt scheduled until max attempts is exhausted; only then does it
              become terminally failed.
            </span>
          </label>

          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Rate limit per minute</span>
            <input
              type="number"
              min="1"
              name="channel[rate_limit_per_minute]"
              value={@form.params["rate_limit_per_minute"]}
              class={ui_field_class(class: "w-full")}
            />
            <span class="text-xs text-sr-muted">Leave blank for no budget.</span>
          </label>
        </div>

        <.failover_fields params={@form.params} channel_index={@channel_index} />

        <div :if={@provider} class="rounded-sr-surface border border-sr-line p-3">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="text-sm font-semibold">Provider configuration</span>
            <.ui_badge size="sm" variant="ghost">
              {config_source_label(@config_contract.source)}
            </.ui_badge>
          </div>
          <p :for={diagnostic <- @config_contract.diagnostics} class="mb-2 text-xs text-warning">
            {diagnostic}
          </p>
          <div
            :if={@mailer_warning}
            class="mb-3 rounded-sr-surface border border-warning/40 bg-warning/10 p-3 text-sm text-warning"
          >
            <div class="font-medium">Outbound mail is not ready</div>
            <p class="mt-1 text-xs">{@mailer_warning}</p>
            <p class="mt-1 text-xs">
              Email channels use the deployment mailer. Configure it under
              Settings -&gt; Mail before sending.
            </p>
          </div>
          <PluginConfigForm.plugin_config_fields
            schema={@config_contract.schema}
            params={@form.config_params || %{}}
            base_name="config"
          />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.ui_button type="submit" size="sm" variant="primary">Save channel</.ui_button>
          <.ui_button
            :if={@can_test}
            type="button"
            size="sm"
            variant="neutral"
            phx-click="test_channel"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> Send test
          </.ui_button>
          <span :if={not @can_test} class="text-xs text-sr-muted">
            Test send needs notifications.test.send.
          </span>
        </div>
      </form>

      <div :if={@test_result} class="mt-4">
        <div class={
          ui_alert_class(variant: if(@test_result.status == :ok, do: "success", else: "error"))
        }>
          <div class="min-w-0">
            <div class="font-medium">{@test_result.headline}</div>
            <p :if={@test_result.error_class} class="text-xs">
              error class {@test_result.error_class}
            </p>
            <p :if={@test_result.detail} class="mt-1 break-words text-xs">{@test_result.detail}</p>
            <dl :if={@test_result.summary != []} class="mt-2 grid grid-cols-2 gap-x-3 text-xs">
              <div :for={{key, value} <- @test_result.summary} class="contents">
                <dt class="text-sr-muted">{key}</dt>
                <dd class="break-words">{value}</dd>
              </div>
            </dl>
            <p class="mt-2 text-xs text-sr-muted">
              A test send is never attributed to an alert. Any delivery row a test writes carries
              is_test and is excluded from every alert notification count.
            </p>
          </div>
        </div>
      </div>
    </.ui_panel>
    """
  end

  attr :params, :map, required: true
  attr :channel_index, :map, default: %{}

  @doc """
  Failover configuration, given its own section rather than two fields in a grid.

  On the `:edge_agent` route these two fields decide whether a page survives the
  site going dark, so they are not interchangeable with rate limits. The section
  is emphasised, states the at-most-once constraint that makes it matter, and
  renders `EdgeRouteSafety.channel_advisory/2` live on every `phx-change` - so
  the consequence of ticking fail closed is on screen at the moment it is
  ticked, not in a delivery log three days later.

  On the `:control_plane` route the advisory is `nil` and the section renders
  plainly, because the condition does not exist when egress is from the platform.
  """
  def failover_fields(assigns) do
    assigns =
      assigns
      |> assign(:edge?, assigns.params["execution_route"] == "edge_agent")
      |> assign(:advisory, EdgeRouteSafety.channel_advisory(assigns.params, assigns.channel_index))

    ~H"""
    <fieldset
      class={[
        "space-y-3 rounded-sr-surface border p-3",
        if(@edge?, do: "border-amber-500/50 bg-amber-500/5", else: "border-sr-line")
      ]}
      data-failover-fields
      data-execution-route={@params["execution_route"]}
    >
      <legend class="px-1 text-sm font-semibold">
        {if @edge?, do: "Failover (required reading on the edge route)", else: "Failover"}
      </legend>

      <p class="text-xs text-sr-muted">
        Failover is one hop, taken when retries are exhausted or the agent is offline. It is not
        escalation: it substitutes a destination for the same page.
      </p>

      <p :if={@edge?} class="text-xs text-sr-muted">
        This channel egresses from a site agent. Agent commands are at-most-once with no
        store-and-forward, and core is the component that detects a site went dark, so these two
        fields decide whether the site-down page for this site can be delivered at all.
      </p>

      <.channel_failover_advisory advisory={@advisory} />

      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <label class="space-y-1">
          <span class="text-sm font-medium text-sr-ink">Failover channel</span>
          <select name="channel[fallback_channel_id]" class={ui_field_class(class: "w-full")}>
            <option value="">None</option>
            <option
              :for={{id, channel} <- Enum.sort_by(@channel_index, fn {_id, c} -> c.name end)}
              :if={id != @params["id"]}
              value={id}
              selected={id == @params["fallback_channel_id"]}
            >
              {channel.name} ({Presentation.execution_route_label(channel.execution_route)})
            </option>
          </select>
          <span class="text-xs text-sr-muted">
            {if @edge?,
              do:
                "Pick a control-plane channel: it is the only one that can page while this site is unreachable.",
              else: "One hop, taken when retries are exhausted."}
          </span>
        </label>

        <label class="flex items-start gap-2 pt-6">
          <input type="hidden" name="channel[fail_closed]" value="false" />
          <input
            type="checkbox"
            name="channel[fail_closed]"
            value="true"
            checked={truthy?(@params["fail_closed"])}
            class={ui_checkbox_class()}
          />
          <span class="space-y-1">
            <span class="block text-sm text-sr-ink">Fail closed (never fail over)</span>
            <span :if={@edge?} class="block text-xs text-sr-muted">
              On a site-agent channel this is a decision to drop the page rather than deliver it
              somewhere else. Leave it off unless a page reaching another destination is worse
              than no page at all.
            </span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr :advisory, :map, default: nil

  @doc """
  The compact form of the advisory, for the saved channel row.

  Carries the full sentence as a title so the row states the condition and the
  operator can read the reasoning without opening the editor. The badge text
  alone carries the meaning; the colour is never the only signal.
  """
  def channel_failover_badge(assigns) do
    ~H"""
    <.state_badge
      :if={@advisory}
      label={@advisory.badge}
      variant={advisory_variant(@advisory)}
      hint={@advisory.message}
    />
    """
  end

  attr :advisory, :map, default: nil

  @doc """
  The per-channel edge-failover advisory (design D3, mitigation 1).

  Rendered in the editor and, in compact badge form, on the saved channel row.
  Like the policy warning it never blocks a save: an operator may knowingly ship
  a fail-closed site channel, and the requirement is that they are told.
  """
  def channel_failover_advisory(assigns) do
    ~H"""
    <div
      :if={@advisory}
      class={ui_alert_class(variant: advisory_variant(@advisory))}
      data-channel-failover-advisory={@advisory && to_string(@advisory.level)}
    >
      <div>
        <div class="font-medium">{@advisory.headline}</div>
        <p class="mt-1">{@advisory.message}</p>
        <p :if={@advisory.remediation} class="mt-1">{@advisory.remediation}</p>
      </div>
    </div>
    """
  end

  # --- routes and escalation -------------------------------------------------

  attr :streams, :any, required: true
  attr :can_manage, :boolean, default: false
  attr :route_form, :map, default: nil
  attr :policy_form, :map, default: nil
  attr :policies, :list, default: []
  attr :schedules, :list, default: []
  attr :channel_index, :map, default: %{}
  attr :policy_warnings, :map, default: %{}
  attr :preview, :map, default: nil
  attr :loading, :boolean, default: false

  def routes_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Routes</div>
            <p class="text-xs text-sr-muted">
              Evaluated in ascending priority. When continue is off the first matching route wins
              and evaluation stops - the same semantics Alertmanager gives the same name.
            </p>
          </div>
          <.ui_button :if={@can_manage} size="sm" variant="primary" phx-click="new_route">
            <.icon name="hero-plus" class="size-4" /> New route
          </.ui_button>
        </:header>

        <.loading_skeleton loading={@loading} />

        <div :if={not @loading} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm", class: "w-full")}>
            <thead>
              <tr>
                <th scope="col">Priority</th>
                <th scope="col">Route</th>
                <th scope="col">Matches</th>
                <th scope="col">Escalation policy</th>
                <th scope="col">Schedule</th>
                <th scope="col">Cadence</th>
                <th scope="col">Continue</th>
                <th scope="col" class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody id="notification-routes" phx-update="stream">
              <tr :for={{dom_id, route} <- @streams.routes} id={dom_id}>
                <td class="font-mono text-xs">{route.priority}</td>
                <td>
                  <div class="font-medium text-sr-ink">{route.name}</div>
                  <.state_badge
                    label={if route.enabled, do: "Enabled", else: "Disabled"}
                    variant={if route.enabled, do: "success", else: "ghost"}
                  />
                </td>
                <td class="max-w-xs break-words text-xs text-sr-muted">
                  {Predicate.summarize(route.match_expression)}
                </td>
                <td class="text-xs">
                  <div>{policy_name(route)}</div>
                  <.state_badge
                    :if={Map.has_key?(@policy_warnings, to_string(route.escalation_policy_id))}
                    label="Edge-only ladder"
                    variant="warning"
                    hint={EdgeRouteSafety.remediation()}
                  />
                </td>
                <td class="text-xs text-sr-muted">{schedule_name(route)}</td>
                <td class="text-xs text-sr-muted">
                  <div>throttle {route.throttle_seconds || "-"}s</div>
                  <div>group wait {route.group_wait_seconds}s</div>
                  <div>group interval {route.group_interval_seconds || "-"}s</div>
                  <div :if={route.dedupe_key_template}>
                    dedupe {Presentation.truncate(route.dedupe_key_template, 40)}
                  </div>
                </td>
                <td>
                  <.state_badge
                    label={if route.continue, do: "Continue", else: "Terminal"}
                    variant={if route.continue, do: "info", else: "ghost"}
                  />
                </td>
                <td class="text-right">
                  <div class="inline-flex gap-1">
                    <.ui_button
                      :if={@can_manage}
                      size="xs"
                      variant="ghost"
                      phx-click="move_route"
                      phx-value-id={route.id}
                      phx-value-direction="up"
                      aria-label={"Raise priority of #{route.name}"}
                    >
                      <.icon name="hero-arrow-up" class="size-3.5" />
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage}
                      size="xs"
                      variant="ghost"
                      phx-click="move_route"
                      phx-value-id={route.id}
                      phx-value-direction="down"
                      aria-label={"Lower priority of #{route.name}"}
                    >
                      <.icon name="hero-arrow-down" class="size-3.5" />
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage}
                      size="xs"
                      variant="ghost"
                      phx-click="edit_route"
                      phx-value-id={route.id}
                    >
                      Edit
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage}
                      size="xs"
                      variant="ghost"
                      phx-click="toggle_route"
                      phx-value-id={route.id}
                    >
                      {if route.enabled, do: "Disable", else: "Enable"}
                    </.ui_button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.ui_panel>

      <.route_editor :if={@route_form} form={@route_form} policies={@policies} schedules={@schedules} />

      <.routing_preview preview={@preview} />

      <.policies_panel
        policies={@policies}
        can_manage={@can_manage}
        channel_index={@channel_index}
        policy_warnings={@policy_warnings}
      />

      <.policy_editor :if={@policy_form} form={@policy_form} channel_index={@channel_index} />
    </div>
    """
  end

  attr :form, :map, required: true
  attr :policies, :list, default: []
  attr :schedules, :list, default: []

  def route_editor(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            {if @form.mode == :new, do: "New route", else: "Edit route"}
          </div>
          <p class="text-xs text-sr-muted">
            Predicate fields come from the same allow-list the dispatch-time evaluator resolves, so
            a route cannot save cleanly and then match nothing.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_route_form">
          Close
        </.ui_button>
      </:header>

      <form phx-change="validate_route" phx-submit="save_route" class="space-y-4">
        <div :if={@form[:error]} class={ui_alert_class(variant: "error")}>{@form.error}</div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Name</span>
            <input
              type="text"
              name="route[name]"
              value={@form.params["name"]}
              required
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Priority</span>
            <input
              type="number"
              name="route[priority]"
              value={@form.params["priority"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Escalation policy</span>
            <select name="route[escalation_policy_id]" class={ui_field_class(class: "w-full")}>
              <option value="">Select a policy</option>
              <option
                :for={policy <- @policies}
                value={policy.id}
                selected={to_string(policy.id) == @form.params["escalation_policy_id"]}
              >
                {policy.name}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Schedule</span>
            <select name="route[schedule_id]" class={ui_field_class(class: "w-full")}>
              <option value="">Always</option>
              <option
                :for={schedule <- @schedules}
                value={schedule.id}
                selected={to_string(schedule.id) == @form.params["schedule_id"]}
              >
                {schedule.name}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Throttle seconds</span>
            <input
              type="number"
              min="0"
              name="route[throttle_seconds]"
              value={@form.params["throttle_seconds"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Group wait seconds</span>
            <input
              type="number"
              min="0"
              name="route[group_wait_seconds]"
              value={@form.params["group_wait_seconds"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Group interval seconds</span>
            <input
              type="number"
              min="0"
              name="route[group_interval_seconds]"
              value={@form.params["group_interval_seconds"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Dedupe key template</span>
            <input
              type="text"
              name="route[dedupe_key_template]"
              value={@form.params["dedupe_key_template"]}
              class={ui_field_class(class: "w-full")}
            />
            <span class="text-xs text-sr-muted">
              Optional override. Left blank the engine uses the existing incident identity.
            </span>
          </label>
          <label class="flex items-center gap-2 pt-6">
            <input type="hidden" name="route[continue]" value="false" />
            <input
              type="checkbox"
              name="route[continue]"
              value="true"
              checked={truthy?(@form.params["continue"])}
              class={ui_checkbox_class()}
            />
            <span class="text-sm text-sr-ink">Continue to lower priority routes</span>
          </label>
        </div>

        <div class="rounded-sr-surface border border-sr-line p-3">
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <div class="text-sm font-semibold">Match expression</div>
            <label class="flex items-center gap-2 text-xs text-sr-muted">
              Combine with
              <select name="route[combinator]" class={ui_field_class(size: "xs", class: "w-24")}>
                <option value="all" selected={@form.params["combinator"] == "all"}>ALL (AND)</option>
                <option value="any" selected={@form.params["combinator"] == "any"}>ANY (OR)</option>
              </select>
            </label>
          </div>

          <div :if={@form[:raw_expression]} class={ui_alert_class(variant: "info", class: "mb-2")}>
            This route uses a nested expression the row builder cannot represent. It is shown
            read-only; editing the rows below would change what it means.
          </div>

          <div class="space-y-2">
            <div
              :for={{row, index} <- Enum.with_index(@form.rows)}
              class="grid grid-cols-1 gap-2 md:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,2fr)_auto]"
            >
              <select
                name={"route[rows][#{index}][field]"}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Predicate field"
              >
                <option
                  :for={field <- Predicate.field_options()}
                  value={field}
                  selected={field == row["field"]}
                >
                  {field}
                </option>
                <option
                  :if={row["field"] not in Predicate.field_options()}
                  value={row["field"]}
                  selected
                >
                  {row["field"]}
                </option>
              </select>
              <select
                name={"route[rows][#{index}][operator]"}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Predicate operator"
              >
                <option
                  :for={operator <- Predicate.operators()}
                  value={operator}
                  selected={operator == row["operator"]}
                >
                  {operator}
                </option>
              </select>
              <input
                type="text"
                name={"route[rows][#{index}][value]"}
                value={row["value"]}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Predicate value"
              />
              <.ui_button
                type="button"
                size="xs"
                variant="ghost"
                phx-click="remove_predicate_row"
                phx-value-index={index}
                aria-label="Remove predicate row"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </.ui_button>
            </div>
          </div>

          <p class="mt-2 text-xs text-sr-muted">
            Free-form incident keys are matchable by prefix: {Enum.join(
              Predicate.field_prefixes(),
              ", "
            )}
          </p>

          <.ui_button
            type="button"
            size="xs"
            variant="ghost"
            class="mt-2"
            phx-click="add_predicate_row"
          >
            <.icon name="hero-plus" class="size-3.5" /> Add condition
          </.ui_button>
        </div>

        <div class="flex flex-wrap gap-2">
          <.ui_button type="submit" size="sm" variant="primary">Save route</.ui_button>
          <.ui_button type="button" size="sm" variant="neutral" phx-click="preview_routing">
            Preview evaluation
          </.ui_button>
        </div>
      </form>
    </.ui_panel>
    """
  end

  attr :preview, :map, default: nil

  def routing_preview(assigns) do
    ~H"""
    <.ui_panel :if={@preview}>
      <:header>
        <div>
          <div class="text-sm font-semibold">Evaluation preview</div>
          <p class="text-xs text-sr-muted">
            {@preview.description}
          </p>
        </div>
      </:header>

      <.empty_state
        :if={@preview.rows == []}
        message="No route claimed the sample alert. The dispatcher would record a suppressed delivery with reason no matching route."
      />

      <ol :if={@preview.rows != []} class="space-y-2">
        <li
          :for={row <- @preview.rows}
          class="flex flex-wrap items-center gap-2 rounded-sr-control border border-sr-line px-3 py-2 text-sm"
        >
          <span class="font-mono text-xs text-sr-muted">{row.priority}</span>
          <span class="font-medium">{row.name}</span>
          <.state_badge label={row.status_label} variant={row.status_variant} />
          <span class="text-xs text-sr-muted">{row.note}</span>
        </li>
      </ol>
    </.ui_panel>
    """
  end

  attr :policies, :list, default: []
  attr :can_manage, :boolean, default: false
  attr :channel_index, :map, default: %{}
  attr :policy_warnings, :map, default: %{}

  def policies_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">Escalation policies</div>
          <p class="text-xs text-sr-muted">
            A step holds a SET of channels: several channels in one step is fan-out, a later step
            gated on non-acknowledgement is escalation. Step delays are measured from the alert
            fire time, not from the previous dispatch.
          </p>
        </div>
        <.ui_button :if={@can_manage} size="sm" variant="primary" phx-click="new_policy">
          <.icon name="hero-plus" class="size-4" /> New policy
        </.ui_button>
      </:header>

      <.empty_state :if={@policies == []} message="No escalation policies yet." />

      <div :for={policy <- @policies} class="space-y-2 border-b border-sr-line py-3 last:border-b-0">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div class="font-medium text-sr-ink">{policy.name}</div>
            <div class="text-xs text-sr-muted">
              repeat {policy.repeat_count}x every {policy.repeat_interval_seconds}s;
              resolve notifies {if policy.resolve_notifies, do: "yes", else: "no"}
            </div>
          </div>
          <.ui_button
            :if={@can_manage}
            size="xs"
            variant="ghost"
            phx-click="edit_policy"
            phx-value-id={policy.id}
          >
            Edit
          </.ui_button>
        </div>

        <.edge_route_warning warning={Map.get(@policy_warnings, to_string(policy.id))} />

        <ol class="space-y-1">
          <li
            :for={step <- policy_steps(policy)}
            class="flex flex-wrap items-baseline gap-2 rounded-sr-control bg-sr-subtle/60 px-3 py-2 text-sm"
          >
            <span class="font-mono text-xs text-sr-muted">t+{humanize_delay(step.delay_seconds)}</span>
            <span class="text-xs text-sr-muted">step {step.step_number}</span>
            <.state_badge
              label={if step.condition == :always, do: "always", else: "if unacknowledged"}
              variant={if step.condition == :always, do: "info", else: "warning"}
            />
            <span class="flex flex-wrap gap-1">
              <.ui_badge
                :for={channel_id <- step_channel_ids(step)}
                size="xs"
                variant={channel_badge_variant(channel_id, @channel_index)}
              >
                {channel_label(channel_id, @channel_index)}
              </.ui_badge>
            </span>
            <span :if={step_channel_ids(step) == []} class="text-xs text-error">
              no channel: this step delivers nothing
            </span>
            <span :if={degraded_channels(step, @channel_index) != []} class="text-xs text-warning">
              {Enum.join(degraded_channels(step, @channel_index), ", ")} unavailable; deliveries to
              this step record suppression reason channel disabled
            </span>
          </li>
        </ol>
      </div>
    </.ui_panel>
    """
  end

  attr :warning, :map, default: nil

  @doc """
  The edge-only escalation warning (design D3).

  Non-blocking by design: an operator may knowingly ship an edge-only ladder. It
  renders on the policy row and on every route bound to the policy, not only
  inside the editor at save time, because the configuration is still wrong after
  the editor closes.
  """
  def edge_route_warning(assigns) do
    ~H"""
    <div :if={@warning} class={ui_alert_class(variant: "warning")} data-edge-route-warning>
      <div>
        <div class="font-medium">This policy cannot deliver a site-down page</div>
        <p class="mt-1">{@warning.message}</p>
        <p class="mt-1">{@warning.remediation}</p>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :channel_index, :map, default: %{}

  def policy_editor(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            {if @form.mode == :new, do: "New escalation policy", else: "Edit escalation policy"}
          </div>
          <p class="text-xs text-sr-muted">
            Steps renumber contiguously from 1 as they are added, removed, or reordered.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_policy_form">
          Close
        </.ui_button>
      </:header>

      <form phx-change="validate_policy" phx-submit="save_policy" class="space-y-4">
        <div :if={@form[:error]} class={ui_alert_class(variant: "error")}>{@form.error}</div>
        <.edge_route_warning warning={@form[:warning]} />

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Name</span>
            <input
              type="text"
              name="policy[name]"
              value={@form.params["name"]}
              required
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Repeat count</span>
            <input
              type="number"
              min="0"
              name="policy[repeat_count]"
              value={@form.params["repeat_count"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Repeat interval seconds</span>
            <input
              type="number"
              min="0"
              name="policy[repeat_interval_seconds]"
              value={@form.params["repeat_interval_seconds"]}
              class={ui_field_class(class: "w-full")}
            />
            <span class="text-xs text-sr-muted">
              The alert rule's renotify interval is the floor: a policy may only make repeats less
              frequent, never more.
            </span>
          </label>
          <label class="flex items-center gap-2 pt-6">
            <input type="hidden" name="policy[resolve_notifies]" value="false" />
            <input
              type="checkbox"
              name="policy[resolve_notifies]"
              value="true"
              checked={truthy?(@form.params["resolve_notifies"])}
              class={ui_checkbox_class()}
            />
            <span class="text-sm text-sr-ink">Notify on resolve</span>
          </label>
        </div>

        <div class="space-y-3">
          <div
            :for={{step, index} <- Enum.with_index(@form.steps)}
            class="rounded-sr-surface border border-sr-line p-3"
          >
            <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
              <div class="text-sm font-semibold">
                Step {index + 1} - t+{humanize_delay(parse_int(step["delay_seconds"]))}
              </div>
              <div class="flex gap-1">
                <.ui_button
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="move_step"
                  phx-value-index={index}
                  phx-value-direction="up"
                  aria-label={"Move step #{index + 1} earlier"}
                >
                  <.icon name="hero-arrow-up" class="size-3.5" />
                </.ui_button>
                <.ui_button
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="move_step"
                  phx-value-index={index}
                  phx-value-direction="down"
                  aria-label={"Move step #{index + 1} later"}
                >
                  <.icon name="hero-arrow-down" class="size-3.5" />
                </.ui_button>
                <.ui_button
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="remove_step"
                  phx-value-index={index}
                  aria-label={"Remove step #{index + 1}"}
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </.ui_button>
              </div>
            </div>

            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <label class="space-y-1">
                <span class="text-sm font-medium text-sr-ink">Delay seconds from alert fire</span>
                <input
                  type="number"
                  min="0"
                  name={"policy[steps][#{index}][delay_seconds]"}
                  value={step["delay_seconds"]}
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </label>
              <label class="space-y-1">
                <span class="text-sm font-medium text-sr-ink">Condition</span>
                <select
                  name={"policy[steps][#{index}][condition]"}
                  class={ui_field_class(size: "sm", class: "w-full")}
                >
                  <option value="always" selected={step["condition"] == "always"}>Always</option>
                  <option
                    value="if_unacknowledged"
                    selected={step["condition"] == "if_unacknowledged"}
                  >
                    If unacknowledged
                  </option>
                </select>
              </label>
            </div>

            <fieldset class="mt-3">
              <legend class="text-sm font-medium text-sr-ink">
                Channels (a set - every one is paged at this step)
              </legend>
              <div class="mt-1 grid grid-cols-1 gap-1 md:grid-cols-3">
                <label
                  :for={{id, channel} <- Enum.sort_by(@channel_index, fn {_id, c} -> c.name end)}
                  class="flex items-center gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    name={"policy[steps][#{index}][channel_ids][]"}
                    value={id}
                    checked={id in (step["channel_ids"] || [])}
                    class={ui_checkbox_class(size: "xs")}
                  />
                  <span>{channel.name}</span>
                  <span class="text-xs text-sr-muted">
                    {Presentation.execution_route_label(channel.execution_route)}
                  </span>
                </label>
              </div>
              <p :if={(step["channel_ids"] || []) == []} class="mt-1 text-xs text-error">
                A step must name at least one channel.
              </p>
            </fieldset>
          </div>
        </div>

        <div class="flex flex-wrap gap-2">
          <.ui_button type="button" size="sm" variant="neutral" phx-click="add_step">
            <.icon name="hero-plus" class="size-4" /> Add step
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Save policy</.ui_button>
        </div>
      </form>
    </.ui_panel>
    """
  end

  # --- silences -------------------------------------------------------------

  attr :streams, :any, required: true
  attr :can_manage, :boolean, default: false
  attr :silence_form, :map, default: nil
  attr :suppression, :map, default: nil
  attr :silence_counts, :map, default: %{}
  attr :loading, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def silences_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Currently suppressed</div>
            <p class="text-xs text-sr-muted">
              What is being withheld right now, by reason, across every suppression source the
              platform evaluates. Each reason links into the Delivery Log filtered to it.
            </p>
          </div>
        </:header>

        <.loading_skeleton loading={@loading} />

        <div :if={not @loading and @suppression}>
          <.empty_state
            :if={@suppression.counts == []}
            message="Nothing is being suppressed in this window."
          />
          <div class="grid grid-cols-2 gap-2 md:grid-cols-3 lg:grid-cols-5">
            <.link
              :for={{reason, count} <- @suppression.counts}
              patch={
                ~p"/settings/notifications/deliveries?#{%{"suppression_reason" => to_string(reason), "state" => "suppressed"}}"
              }
              class="rounded-sr-control border border-sr-line px-3 py-2 hover:bg-sr-subtle"
            >
              <div class="text-lg font-semibold text-sr-ink">{count}</div>
              <div class="text-xs text-sr-ink/80">
                {Presentation.suppression_reason_label(reason)}
              </div>
              <div class="mt-1 text-[11px] leading-tight text-sr-muted">
                {Presentation.suppression_reason_explanation(reason)}
              </div>
            </.link>
          </div>
          <p :if={@suppression.saturated?} class="mt-2 text-xs text-sr-muted">
            Counts are a floor: the sample of {@suppression.sampled} withheld decisions was
            saturated. Narrow the window in the Delivery Log for an exact figure.
          </p>
        </div>
      </.ui_panel>

      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Silences</div>
            <p class="text-xs text-sr-muted">
              A silence never deletes a notification: matching dispatches are recorded as
              suppressed with reason silence, so they stay answerable in the Delivery Log.
            </p>
          </div>
          <.ui_button :if={@can_manage} size="sm" variant="primary" phx-click="new_silence">
            <.icon name="hero-plus" class="size-4" /> New silence
          </.ui_button>
        </:header>

        <div :if={not @loading} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm", class: "w-full")}>
            <thead>
              <tr>
                <th scope="col">Silence</th>
                <th scope="col">State</th>
                <th scope="col">Window</th>
                <th scope="col">Matches</th>
                <th scope="col">Comment</th>
                <th scope="col">Suppressed</th>
                <th scope="col" class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody id="notification-silences" phx-update="stream">
              <tr :for={{dom_id, silence} <- @streams.silences} id={dom_id}>
                <td>
                  <div class="font-medium text-sr-ink">{silence.name || "(unnamed)"}</div>
                  <div class="text-xs text-sr-muted">
                    by {silence.created_by || "platform user"}
                  </div>
                </td>
                <td>
                  <.state_badge
                    label={Presentation.silence_state_label(silence.state)}
                    variant={Presentation.silence_state_variant(silence.state)}
                  />
                </td>
                <td class="text-xs text-sr-muted">
                  <div>
                    <.user_time
                      id={"notification-silence-#{silence.id}-starts-at"}
                      value={silence.starts_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <div>
                    to
                    <.user_time
                      id={"notification-silence-#{silence.id}-ends-at"}
                      value={silence.ends_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                </td>
                <td class="max-w-xs break-words text-xs text-sr-muted">
                  {Predicate.summarize(silence.matchers)}
                </td>
                <td class="max-w-xs break-words text-xs">{silence.comment}</td>
                <td class="text-xs">
                  <.link
                    patch={
                      ~p"/settings/notifications/deliveries?#{%{"suppression_reason" => "silence", "state" => "suppressed"}}"
                    }
                    class="text-sr-brand hover:underline"
                  >
                    {Map.get(@silence_counts, to_string(silence.id), 0)}
                  </.link>
                </td>
                <td class="text-right">
                  <div class="inline-flex gap-1">
                    <.ui_button
                      :if={@can_manage and silence.state in [:scheduled, :active]}
                      size="xs"
                      variant="ghost"
                      phx-click="edit_silence"
                      phx-value-id={silence.id}
                    >
                      Edit
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and silence.state in [:scheduled, :active]}
                      size="xs"
                      variant="ghost"
                      phx-click="confirm_cancel_silence"
                      phx-value-id={silence.id}
                    >
                      Cancel
                    </.ui_button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.ui_panel>

      <.silence_editor :if={@silence_form} form={@silence_form} />
    </div>
    """
  end

  attr :form, :map, required: true

  def silence_editor(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            {if @form.mode == :new, do: "New silence", else: "Edit silence"}
          </div>
          <p class="text-xs text-sr-muted">
            The creator is taken from your authenticated session; a submitted creator id is
            ignored.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_silence_form">
          Close
        </.ui_button>
      </:header>

      <form phx-change="validate_silence" phx-submit="save_silence" class="space-y-4">
        <div :if={@form[:error]} class={ui_alert_class(variant: "error")}>{@form.error}</div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Name</span>
            <input
              type="text"
              name="silence[name]"
              value={@form.params["name"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Comment (required)</span>
            <input
              type="text"
              name="silence[comment]"
              value={@form.params["comment"]}
              required
              aria-describedby="silence-comment-help"
              class={ui_field_class(class: "w-full")}
            />
            <span id="silence-comment-help" class="text-xs text-sr-muted">
              A silence without a stated reason is indistinguishable from a bug weeks later.
            </span>
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Starts at (UTC)</span>
            <input
              type="datetime-local"
              name="silence[starts_at]"
              value={@form.params["starts_at"]}
              class={ui_field_class(class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-sm font-medium text-sr-ink">Ends at (UTC)</span>
            <input
              type="datetime-local"
              name="silence[ends_at]"
              value={@form.params["ends_at"]}
              required
              class={ui_field_class(class: "w-full")}
            />
          </label>
        </div>

        <div class="rounded-sr-surface border border-sr-line p-3">
          <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
            <div class="text-sm font-semibold">Matchers</div>
            <label class="flex items-center gap-2 text-xs text-sr-muted">
              Combine with
              <select name="silence[combinator]" class={ui_field_class(size: "xs", class: "w-24")}>
                <option value="all" selected={@form.params["combinator"] == "all"}>ALL (AND)</option>
                <option value="any" selected={@form.params["combinator"] == "any"}>ANY (OR)</option>
              </select>
            </label>
          </div>

          <div class="space-y-2">
            <div
              :for={{row, index} <- Enum.with_index(@form.rows)}
              class="grid grid-cols-1 gap-2 md:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,2fr)_auto]"
            >
              <select
                name={"silence[rows][#{index}][field]"}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Matcher field"
              >
                <option
                  :for={field <- Predicate.field_options()}
                  value={field}
                  selected={field == row["field"]}
                >
                  {field}
                </option>
              </select>
              <select
                name={"silence[rows][#{index}][operator]"}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Matcher operator"
              >
                <option
                  :for={operator <- Predicate.operators()}
                  value={operator}
                  selected={operator == row["operator"]}
                >
                  {operator}
                </option>
              </select>
              <input
                type="text"
                name={"silence[rows][#{index}][value]"}
                value={row["value"]}
                class={ui_field_class(size: "sm", class: "w-full")}
                aria-label="Matcher value"
              />
              <.ui_button
                type="button"
                size="xs"
                variant="ghost"
                phx-click="remove_predicate_row"
                phx-value-index={index}
                aria-label="Remove matcher row"
              >
                <.icon name="hero-trash" class="size-3.5" />
              </.ui_button>
            </div>
          </div>

          <.ui_button
            type="button"
            size="xs"
            variant="ghost"
            class="mt-2"
            phx-click="add_predicate_row"
          >
            <.icon name="hero-plus" class="size-3.5" /> Add matcher
          </.ui_button>

          <div :if={@form[:preview]} class={ui_alert_class(variant: "info", class: "mt-3")}>
            <div>
              <div class="font-medium">Blast radius</div>
              <p>
                These matchers match {@form.preview.count} of the {@form.preview.considered} most recent active alerts.
              </p>
              <ul class="mt-1 list-disc space-y-1 pl-5 text-xs">
                <li :for={title <- @form.preview.sample}>{title}</li>
              </ul>
            </div>
          </div>
        </div>

        <.ui_button type="submit" size="sm" variant="primary">Save silence</.ui_button>
      </form>
    </.ui_panel>
    """
  end

  # --- providers ------------------------------------------------------------

  attr :streams, :any, required: true
  attr :can_manage, :boolean, default: false
  attr :upload, :map, default: nil
  attr :versions, :map, default: nil
  attr :loading, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def providers_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Providers</div>
            <p class="text-xs text-sr-muted">
              Three tiers are authorable - native, declarative, and Wasm plugin. Stream is a
              built-in provider type, not a tier: an operator cannot author one.
            </p>
          </div>
          <.ui_button
            :if={@can_manage}
            size="sm"
            variant="primary"
            phx-click="new_provider_upload"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload definition
          </.ui_button>
        </:header>

        <.loading_skeleton loading={@loading} />

        <div :if={not @loading} class="overflow-x-auto">
          <table class={ui_table_class(size: "sm", class: "w-full")}>
            <thead>
              <tr>
                <th scope="col">Provider</th>
                <th scope="col">Type</th>
                <th scope="col">Provenance</th>
                <th scope="col">Status</th>
                <th scope="col">Capabilities</th>
                <th scope="col">Routes / formats</th>
                <th scope="col" class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody id="notification-providers" phx-update="stream">
              <tr :for={{dom_id, provider} <- @streams.providers} id={dom_id}>
                <td>
                  <div class="font-medium text-sr-ink">{provider.display_name}</div>
                  <div class="font-mono text-xs text-sr-muted">{provider.provider_key}</div>
                </td>
                <td class="text-xs">
                  <div>{Presentation.provider_type_label(provider.provider_type)}</div>
                  <.state_badge
                    :if={Presentation.builtin_type?(provider.provider_type)}
                    label="Built-in type"
                    variant="info"
                  />
                  <div class="text-sr-muted">
                    {Presentation.provider_type_explanation(provider.provider_type)}
                  </div>
                </td>
                <td class="text-xs">
                  <.state_badge
                    label={Presentation.provider_source_label(provider.source)}
                    variant={Presentation.provider_source_variant(provider.source)}
                  />
                  <div :if={provider.managed} class="mt-1 text-sr-muted">
                    Managed: template {provider.template_version || "-"} is reconciled on upgrade
                    while its fingerprint still matches. Your edits to non-managed fields are
                    preserved.
                  </div>
                </td>
                <td>
                  <.state_badge
                    label={Presentation.provider_status_label(provider.status)}
                    variant={Presentation.provider_status_variant(provider.status)}
                  />
                  <div class="text-xs text-sr-muted">v{provider.definition_version}</div>
                </td>
                <td class="text-xs text-sr-muted">
                  {Enum.map_join(provider.capabilities || [], ", ", &to_string/1)}
                </td>
                <td class="text-xs text-sr-muted">
                  <div>{Enum.map_join(provider.supported_routes || [], ", ", &to_string/1)}</div>
                  <div>{Enum.map_join(provider.payload_formats || [], ", ", &to_string/1)}</div>
                </td>
                <td class="text-right">
                  <div class="inline-flex gap-1">
                    <.ui_button
                      :if={@can_manage and provider.provider_type == :declarative}
                      size="xs"
                      variant="ghost"
                      phx-click="show_provider_versions"
                      phx-value-id={provider.id}
                    >
                      Versions
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and provider.provider_type == :declarative}
                      size="xs"
                      variant="ghost"
                      phx-click="replace_provider_definition"
                      phx-value-id={provider.id}
                    >
                      New version
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and provider.status != :disabled}
                      size="xs"
                      variant="ghost"
                      phx-click="confirm_disable_provider"
                      phx-value-id={provider.id}
                    >
                      Disable
                    </.ui_button>
                    <.ui_button
                      :if={@can_manage and provider.status != :active}
                      size="xs"
                      variant="ghost"
                      phx-click="enable_provider"
                      phx-value-id={provider.id}
                    >
                      Activate
                    </.ui_button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.ui_panel>

      <.provider_upload_editor :if={@upload} form={@upload} />

      <.provider_versions_panel
        :if={@versions}
        versions={@versions}
        can_manage={@can_manage}
        timezone={@timezone}
      />

      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Add a provider without a release</div>
          </div>
        </:header>
        <p class="text-sm text-sr-ink/80">
          Uploading a declarative definition adds a destination with no code and no release. The
          only authorable tier here is {Enum.map_join(
            Presentation.authorable_tiers(),
            ", ",
            &Presentation.provider_type_label/1
          )},
          because a native provider is resolved from a compile-time allowlist and a Wasm provider
          ships as a signed package.
        </p>
        <p class="mt-2 text-xs text-sr-muted">
          A definition is data: YAML or JSON describing one HTTP request. It carries no markup and
          no code, its templates address the published variable catalog plus the config and secrets
          fields it declares itself, and every resolved URL still passes the outbound policy at
          request time.
        </p>
        <p class="mt-2 text-xs text-sr-muted">
          The stream provider publishes the canonical envelope to an RBAC-scoped firehose gated by
          notifications.stream.subscribe. A suppressed dispatch publishes nothing there: the
          Delivery Log, not the stream, is where a withheld notification is answerable.
        </p>
      </.ui_panel>
    </div>
    """
  end

  attr :form, :map, required: true

  @doc """
  The declarative definition editor.

  Two properties are the point of this component. Validation feedback names the
  offending PATH and repeats the validator's own sentence - a generic "invalid
  document" would leave an operator bisecting their own YAML - and the rendered
  preview shows the request the document would issue, with every substitution
  point marked, so a template that landed in the wrong field is visible before
  the provider is saved rather than during an incident.

  Nothing here is rendered through `raw/1`. A definition is operator-supplied
  input and is echoed back to the page in full, so every part of it - error
  paths, error messages, the preview, the document itself - is interpolated as
  text and escaped by the template.
  """
  def provider_upload_editor(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            {if @form.mode == :replace,
              do: "New version of " <> to_string(@form.provider_key),
              else: "Upload a provider definition"}
          </div>
          <p class="text-xs text-sr-muted">
            YAML or JSON, up to {ProviderUpload.max_document_bytes()} bytes. Nothing is written
            until the document validates, and saving never rewrites an existing version: it
            writes the next one, so deliveries already recorded keep naming the version that
            rendered them.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="cancel_provider_upload">
          Close
        </.ui_button>
      </:header>

      <form
        id="provider-upload-form"
        phx-change="validate_provider_upload"
        phx-submit="save_provider_upload"
        class="space-y-4"
      >
        <div :if={@form[:error]} class={ui_alert_class(variant: "error")}>{@form.error}</div>

        <label class="block space-y-1">
          <span class="text-sm font-medium text-sr-ink">Definition document</span>
          <textarea
            name="provider[document]"
            rows="16"
            spellcheck="false"
            phx-debounce="500"
            aria-describedby="provider-document-help"
            class={ui_field_class(class: "w-full font-mono text-xs")}
          >{@form.params["document"]}</textarea>
          <span id="provider-document-help" class="text-xs text-sr-muted">
            YAML anchors and aliases are not resolved by the decoder, so write values out or
            supply JSON. The preview below is where an alias that silently collapsed becomes
            visible.
          </span>
        </label>

        <div :if={@form.errors != []} class={ui_alert_class(variant: "error")} role="alert">
          <div>
            <div class="font-medium">
              This document was not accepted: {length(@form.errors)} {if length(@form.errors) == 1,
                do: "problem",
                else: "problems"}
            </div>
            <ul class="mt-2 space-y-1 text-xs">
              <li :for={error <- @form.errors} class="flex flex-col gap-0.5 md:flex-row md:gap-2">
                <span class="font-mono font-medium text-sr-ink">{error.path}</span>
                <span>{error.message}</span>
              </li>
            </ul>
          </div>
        </div>

        <.provider_request_preview :if={@form.preview} preview={@form.preview} />

        <.ui_button
          type="submit"
          size="sm"
          variant="primary"
          disabled={is_nil(@form.definition)}
        >
          Save definition
        </.ui_button>
      </form>
    </.ui_panel>
    """
  end

  attr :preview, :map, required: true

  @doc """
  The request a definition would issue, with placeholders where values go.

  The markers (`<alert.title>`, `<config.webhook_url>`, `<secrets.token>`) are
  written by
  `ServiceRadarWebNGWeb.Settings.NotificationsLive.ProviderUpload`; no channel
  configuration and no credential is resolved to render this. A preview that
  showed a plausible value where a secret goes would teach an operator to expect
  one.
  """
  def provider_request_preview(assigns) do
    ~H"""
    <div class="rounded-sr-surface border border-sr-line p-3">
      <div class="text-sm font-semibold">Rendered request</div>
      <p class="mt-1 text-xs text-sr-muted">
        Substitution points are shown as markers naming the value that will replace them. No
        channel configuration and no credential is read to build this preview.
      </p>

      <dl class="mt-3 space-y-2 text-xs">
        <div class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">Request</dt>
          <dd class="font-mono break-all">{@preview.method} {@preview.url}</dd>
        </div>
        <div :if={@preview.headers != []} class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">Headers</dt>
          <dd class="font-mono break-all">
            <div :for={{name, value} <- @preview.headers}>{name}: {value}</div>
          </dd>
        </div>
        <div class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">
            Body ({@preview.body_format})
          </dt>
          <dd class="min-w-0 grow">
            <pre class="overflow-x-auto rounded-sr-control bg-sr-subtle p-2 font-mono text-xs">{@preview.body}</pre>
          </dd>
        </div>
        <div class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">Outcome</dt>
          <dd>
            Success on {@preview.success}; retried on {@preview.retryable}. Anything else is a
            terminal failure.
          </dd>
        </div>
        <div :if={@preview.fields != []} class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">Channel form</dt>
          <dd>
            <div :for={field <- @preview.fields}>
              <span class="font-mono">{field.name}</span>
              <span class="text-sr-muted">
                {field.title}{if field.required?, do: " (required)", else: ""}{if field.secret?,
                  do: " - stored as a credential reference",
                  else: ""}
              </span>
            </div>
          </dd>
        </div>
        <div :if={@preview.unresolved != []} class="flex flex-col gap-1 md:flex-row md:gap-2">
          <dt class="w-28 shrink-0 font-medium text-sr-ink">Renders empty</dt>
          <dd class="text-sr-muted">
            <span class="font-mono">{Enum.join(@preview.unresolved, ", ")}</span>
            - these are free-form namespaces, so they resolve only when the alert carries them.
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :versions, :map, required: true
  attr :can_manage, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  @doc """
  A declarative provider's definition history, and what binds to it.

  Rolling back writes the older document as a NEW version rather than editing an
  old one, because `NotificationDelivery.provider_version` names the version that
  rendered each delivery and rewriting it would falsify the delivery log. Each
  row therefore links to the deliveries recorded against it.
  """
  def provider_versions_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div>
          <div class="text-sm font-semibold">
            Definition versions - {@versions.provider.display_name}
          </div>
          <p class="text-xs text-sr-muted">
            Rolling back re-uploads an older document as the next version. Deliveries already
            recorded keep naming the version that rendered them, so the audit trail stays true and
            a rollback can itself be rolled back.
          </p>
        </div>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="close_provider_versions">
          Close
        </.ui_button>
      </:header>

      <div class="rounded-sr-surface border border-sr-line p-3 text-xs">
        <div class="font-medium text-sr-ink">
          Channels bound to this provider render at v{@versions.provider.definition_version}
        </div>
        <.empty_state :if={@versions.channels == []} message="No channel is bound to it yet." />
        <ul :if={@versions.channels != []} class="mt-1 list-disc space-y-1 pl-5 text-sr-muted">
          <li :for={channel <- @versions.channels}>
            {channel.name} - {if channel.enabled, do: "enabled", else: "disabled"}
          </li>
        </ul>
      </div>

      <.empty_state
        :if={@versions.entries == []}
        message="No definition version has been recorded for this provider yet."
      />

      <div :if={@versions.entries != []} class="mt-3 space-y-3">
        <div
          :for={entry <- @versions.entries}
          class="rounded-sr-surface border border-sr-line p-3"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <span class="text-sm font-semibold">Version {entry.number}</span>
              <.state_badge :if={entry.current?} label="Current" variant="success" />
              <span class="text-xs text-sr-muted">
                <.user_time
                  id={"notification-provider-#{@versions.provider.id}-version-#{entry.number}-recorded-at"}
                  value={entry.recorded_at}
                  timezone={@timezone}
                  style={:full}
                  fallback="-"
                /> - {entry.action}
              </span>
            </div>
            <div class="inline-flex gap-1">
              <.link
                class="text-xs underline"
                navigate={
                  ~p"/settings/notifications/deliveries?#{%{"provider_version" => entry.number}}"
                }
              >
                Deliveries at v{entry.number}
              </.link>
              <.ui_button
                :if={@can_manage and not entry.current?}
                size="xs"
                variant="ghost"
                phx-click="confirm_rollback_provider"
                phx-value-id={@versions.provider.id}
                phx-value-version={entry.number}
              >
                Roll back to v{entry.number}
              </.ui_button>
            </div>
          </div>

          <details class="mt-2">
            <summary class="cursor-pointer text-xs text-sr-muted">Show the document</summary>
            <pre class="mt-2 overflow-x-auto rounded-sr-control bg-sr-subtle p-2 font-mono text-xs">{Presentation.truncate(ProviderUpload.document_text(entry.definition), 4000)}</pre>
          </details>
        </div>
      </div>
    </.ui_panel>
    """
  end

  # --- delivery log ---------------------------------------------------------

  attr :streams, :any, required: true
  attr :filters, :map, required: true
  attr :channel_index, :map, default: %{}
  attr :selected, :map, default: nil
  attr :limit, :integer, default: 100
  attr :loading, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def deliveries_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.ui_panel>
        <:header>
          <div>
            <div class="text-sm font-semibold">Delivery Log</div>
            <p class="text-xs text-sr-muted">
              Every attempt, including the ones that never went out. A withheld notification is
              recorded with its suppression reason rather than dropped, which is what makes
              "why was I not paged?" answerable.
            </p>
          </div>
        </:header>

        <form phx-change="filter_deliveries" class="grid grid-cols-1 gap-3 md:grid-cols-4">
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">State</span>
            <select name="state" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="">All states</option>
              <option
                :for={{label, value} <- Presentation.delivery_state_options()}
                value={value}
                selected={to_string(@filters.state) == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Suppression reason</span>
            <select name="suppression_reason" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="">Any reason</option>
              <option
                :for={{label, value} <- Presentation.suppression_reason_options()}
                value={value}
                selected={to_string(@filters.suppression_reason) == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Channel</span>
            <select name="channel_id" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="">Any channel</option>
              <option
                :for={{id, channel} <- Enum.sort_by(@channel_index, fn {_id, c} -> c.name end)}
                value={id}
                selected={@filters.channel_id == id}
              >
                {channel.name}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Alert id</span>
            <input
              type="text"
              name="alert_id"
              value={@filters.alert_id}
              phx-debounce="400"
              placeholder="uuid"
              class={ui_field_class(size: "sm", class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Execution route</span>
            <select name="execution_route" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="">Any route</option>
              <option value="control_plane" selected={@filters.execution_route == :control_plane}>
                Control plane
              </option>
              <option value="edge_agent" selected={@filters.execution_route == :edge_agent}>
                Edge agent
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Payload format</span>
            <select name="payload_format" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="">Any format</option>
              <option
                :for={{label, value} <- Presentation.payload_format_options()}
                value={value}
                selected={to_string(@filters.payload_format) == value}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Provider version</span>
            <input
              type="number"
              min="1"
              name="provider_version"
              value={@filters.provider_version}
              phx-debounce="400"
              class={ui_field_class(size: "sm", class: "w-full")}
            />
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Test sends</span>
            <select name="is_test" class={ui_field_class(size: "sm", class: "w-full")}>
              <option value="" selected={is_nil(@filters.is_test)}>Include</option>
              <option value="false" selected={@filters.is_test == false}>Exclude</option>
              <option value="true" selected={@filters.is_test == true}>Only tests</option>
            </select>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-sr-ink">Window</span>
            <select name="window" class={ui_field_class(size: "sm", class: "w-full")}>
              <option
                :for={{label, value} <- DeliveryFilters.window_options()}
                value={value}
                selected={@filters.window == value}
              >
                {label}
              </option>
            </select>
          </label>
          <div class="flex items-end">
            <.ui_button type="button" size="sm" variant="ghost" phx-click="clear_delivery_filters">
              Clear filters
            </.ui_button>
          </div>
        </form>

        <.loading_skeleton loading={@loading} />

        <div :if={not @loading} class="mt-3 overflow-x-auto">
          <table class={ui_table_class(size: "sm", class: "w-full")}>
            <thead>
              <tr>
                <th scope="col">State</th>
                <th scope="col">Alert</th>
                <th scope="col">Channel / step</th>
                <th scope="col">Attempts</th>
                <th scope="col">Dispatch</th>
                <th scope="col">Timing</th>
                <th scope="col" class="text-right">Detail</th>
              </tr>
            </thead>
            <tbody id="notification-deliveries" phx-update="stream">
              <tr :for={{dom_id, delivery} <- @streams.deliveries} id={dom_id}>
                <td>
                  <.state_badge
                    label={Presentation.delivery_state_label(delivery.state)}
                    variant={Presentation.delivery_state_variant(delivery.state)}
                  />
                  <div :if={delivery.suppression_reason} class="mt-1" data-suppression-reason>
                    <.state_badge
                      label={Presentation.suppression_reason_label(delivery.suppression_reason)}
                      variant="warning"
                    />
                    <div class="mt-1 text-[11px] leading-tight text-sr-muted">
                      {Presentation.suppression_reason_explanation(delivery.suppression_reason)}
                    </div>
                    <div :if={delivery.occurrence_count > 1} class="text-[11px] text-sr-muted">
                      recorded {delivery.occurrence_count} times, last
                      <.user_time
                        id={"notification-delivery-#{delivery.id}-last-evaluated-at"}
                        value={delivery.last_evaluated_at}
                        timezone={@timezone}
                        style={:full}
                        fallback="-"
                      />
                    </div>
                  </div>
                  <.state_badge :if={delivery.is_test} label="Test send" variant="info" />
                </td>
                <td class="text-xs">
                  <div class="font-medium text-sr-ink">{alert_title(delivery)}</div>
                  <div class="text-sr-muted">{alert_severity(delivery)}</div>
                  <div :if={is_nil(delivery.alert_id)} class="text-sr-muted">
                    alert no longer available (rendered from snapshot)
                  </div>
                  <div :if={delivery.alert_id} class="font-mono text-[11px] text-sr-muted">
                    {delivery.alert_id}
                  </div>
                </td>
                <td class="text-xs">
                  <div>{channel_label(delivery.channel_id, @channel_index)}</div>
                  <div :if={delivery.step_number} class="text-sr-muted">
                    step {delivery.step_number}
                  </div>
                  <div :if={delivery.dedupe_key} class="font-mono text-[11px] text-sr-muted">
                    {Presentation.truncate(delivery.dedupe_key, 40)}
                  </div>
                </td>
                <td class="text-xs">
                  <div>{delivery.attempt_count} of {delivery.max_attempts}</div>
                  <div :if={delivery.next_attempt_at} class="text-sr-muted">
                    next
                    <.user_time
                      id={"notification-delivery-#{delivery.id}-next-attempt-at"}
                      value={delivery.next_attempt_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <div :if={delivery.error_class} class="text-error">{delivery.error_class}</div>
                  <div :if={delivery.error_message} class="max-w-xs break-words text-sr-muted">
                    {Presentation.truncate(delivery.error_message, 140)}
                  </div>
                </td>
                <td class="text-xs text-sr-muted">
                  <div>{Presentation.execution_route_label(delivery.execution_route)}</div>
                  <div :if={delivery.agent_uid}>agent {delivery.agent_uid}</div>
                  <div :if={delivery.payload_format}>
                    format {delivery.payload_format}
                  </div>
                  <div :if={delivery.provider_version}>
                    provider v{delivery.provider_version}
                  </div>
                  <div :if={delivery.originating_delivery_id} data-failover>
                    <.state_badge label="Failover" variant="warning" />
                  </div>
                </td>
                <td class="text-xs text-sr-muted">
                  <div>
                    queued
                    <.user_time
                      id={"notification-delivery-#{delivery.id}-queued-at"}
                      value={delivery.queued_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <div>
                    started
                    <.user_time
                      id={"notification-delivery-#{delivery.id}-started-at"}
                      value={delivery.started_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                  <div>
                    finished
                    <.user_time
                      id={"notification-delivery-#{delivery.id}-finished-at"}
                      value={delivery.finished_at}
                      timezone={@timezone}
                      style={:full}
                      fallback="-"
                    />
                  </div>
                </td>
                <td class="text-right">
                  <.ui_button
                    size="xs"
                    variant="ghost"
                    phx-click="show_delivery"
                    phx-value-id={delivery.id}
                  >
                    Open
                  </.ui_button>
                </td>
              </tr>
            </tbody>
          </table>
          <p class="mt-2 text-xs text-sr-muted">
            Showing at most {@limit} rows for the selected window. Narrow the filters to move the
            window rather than loading the whole table.
          </p>
        </div>
      </.ui_panel>

      <.delivery_detail
        selected={@selected}
        channel_index={@channel_index}
        timezone={@timezone}
      />
    </div>
    """
  end

  attr :selected, :map, default: nil
  attr :channel_index, :map, default: %{}
  attr :timezone, :string, default: "Etc/UTC"

  def delivery_detail(assigns) do
    ~H"""
    <.ui_modal
      :if={@selected}
      id="notification-delivery-detail"
      size="lg"
      on_cancel={JS.push("close_delivery")}
    >
      <:title>Delivery detail</:title>

      <div class="space-y-3 text-sm">
        <div class="flex flex-wrap gap-2">
          <.state_badge
            label={Presentation.delivery_state_label(@selected.delivery.state)}
            variant={Presentation.delivery_state_variant(@selected.delivery.state)}
          />
          <.state_badge
            :if={@selected.delivery.suppression_reason}
            label={Presentation.suppression_reason_label(@selected.delivery.suppression_reason)}
            variant="warning"
          />
          <.state_badge :if={@selected.delivery.is_test} label="Test send" variant="info" />
        </div>

        <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
          <div class="contents">
            <dt class="text-sr-muted">Channel</dt>
            <dd>{channel_label(@selected.delivery.channel_id, @channel_index)}</dd>
          </div>
          <div class="contents">
            <dt class="text-sr-muted">Correlation id</dt>
            <dd class="break-all font-mono">
              {@selected.delivery.external_correlation_id || "-"}
            </dd>
          </div>
          <div class="contents">
            <dt class="text-sr-muted">Command id</dt>
            <dd class="break-all font-mono">{@selected.delivery.command_id || "-"}</dd>
          </div>
          <div class="contents">
            <dt class="text-sr-muted">Payload digest</dt>
            <dd class="break-all font-mono">
              {@selected.delivery.rendered_payload_digest || "-"}
            </dd>
          </div>
        </dl>

        <div>
          <div class="text-sm font-semibold">Redacted payload summary</div>
          <p class="text-xs text-sr-muted">
            The wire payload is never displayed. This is the redacted summary the engine persisted,
            alongside the digest that identifies the body that actually went out.
          </p>
          <dl class="mt-1 grid grid-cols-2 gap-x-4 text-xs">
            <div
              :for={{key, value} <- Presentation.payload_summary(@selected.delivery.result_summary)}
              class="contents"
            >
              <dt class="text-sr-muted">{key}</dt>
              <dd class="break-words">{value}</dd>
            </div>
          </dl>
          <.contract_view
            id={"delivery-#{@selected.delivery.id}-contract"}
            view={
              Contracts.delivery_view(
                @selected.delivery.result_summary,
                delivery_provider(@selected, @channel_index)
              )
            }
            class="mt-3"
            only_contract={true}
            timezone={@timezone}
          />
        </div>

        <div :if={Presentation.suppressing_silence_id(@selected.delivery.result_summary)}>
          <div class="text-sm font-semibold">Why this was withheld</div>
          <p class="text-xs">
            {Presentation.suppression_reason_explanation(@selected.delivery.suppression_reason)}
            <.link patch={~p"/settings/notifications/silences"} class="text-sr-brand hover:underline">
              Open the silence
            </.link>
            <span class="font-mono">
              ({Presentation.suppressing_silence_id(@selected.delivery.result_summary)})
            </span>
          </p>
        </div>

        <div :if={@selected.chain.origin || @selected.chain.successors != []}>
          <div class="text-sm font-semibold">Failover chain</div>
          <p :if={@selected.chain.origin} class="text-xs">
            This row is a failover from
            <.link
              patch={
                ~p"/settings/notifications/deliveries?#{%{"alert_id" => @selected.chain.origin.alert_id}}"
              }
              class="text-sr-brand hover:underline"
            >
              the attempt on {channel_label(@selected.chain.origin.channel_id, @channel_index)}
            </.link>
            ({Presentation.delivery_state_label(@selected.chain.origin.state)}). It is not an
            independent dispatch.
          </p>
          <ul :if={@selected.chain.successors != []} class="mt-1 list-disc pl-5 text-xs">
            <li :for={successor <- @selected.chain.successors}>
              failed over to {channel_label(successor.channel_id, @channel_index)} - {Presentation.delivery_state_label(
                successor.state
              )}
            </li>
          </ul>
        </div>
      </div>

      <:actions>
        <.ui_button type="button" size="sm" variant="ghost" phx-click="close_delivery">Close</.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  # --- helpers --------------------------------------------------------------

  defp provider_name(%{provider: %{display_name: name}}) when is_binary(name), do: name
  defp provider_name(_channel), do: "(provider unavailable)"

  # --- package-supplied contract rendering (tasks 3.5.4) ---------------------
  #
  # The widget renderer is the SAME one the events and logs pages use
  # (`SignalDisplayComponents.signal_display_widget/1`). Notifications get a
  # second surface for package contracts, not a second renderer: a widget type
  # that rendered one way on an event page and another way in the Delivery Log
  # would be two contracts wearing one name.

  attr :view, :map, required: true
  attr :id, :string, required: true
  attr :timezone, :string, required: true
  attr :class, :string, default: nil

  attr :only_contract, :boolean,
    default: false,
    doc:
      "Render nothing when the view degraded to the generic form. Used where the " <>
        "surrounding markup already shows the generic view."

  defp contract_view(assigns) do
    ~H"""
    <div :if={render_contract_view?(@view, @only_contract)} class={@class}>
      <div class="space-y-3">
        <.signal_display_widget
          :for={{widget, widget_index} <- Enum.with_index(@view.widgets)}
          id={"#{@id}-widget-#{widget_index}"}
          widget={widget}
          timezone={@timezone}
        />
      </div>
      <p :for={diagnostic <- @view.diagnostics} class="mt-1 text-xs text-warning">
        {diagnostic}
      </p>
    </div>
    """
  end

  defp render_contract_view?(%{widgets: []}, _only_contract), do: false
  defp render_contract_view?(%{source: :generic}, true), do: false
  defp render_contract_view?(_view, _only_contract), do: true

  defp config_source_label(:package), do: "from the package manifest"
  defp config_source_label(:provider), do: "from the provider record"
  defp config_source_label(_source), do: "no configuration schema"

  defp channel_provider(%{provider: provider}) when is_struct(provider, Ash.NotLoaded), do: nil
  defp channel_provider(%{provider: %{} = provider}), do: provider
  defp channel_provider(_channel), do: nil

  defp delivery_provider(%{delivery: %{channel_id: channel_id}}, channel_index) when not is_nil(channel_id) do
    channel_index
    |> Map.get(to_string(channel_id))
    |> channel_provider()
  end

  defp delivery_provider(_selected, _channel_index), do: nil

  defp provider_field(%{provider: provider}, key) when is_map(provider), do: Map.get(provider, key)
  defp provider_field(_channel, _key), do: nil

  defp provider_default_attempts(%{default_max_attempts: value}) when is_integer(value), do: value
  defp provider_default_attempts(_provider), do: 3

  defp supported_routes(%{supported_routes: routes}) when is_list(routes), do: routes
  defp supported_routes(_provider), do: [:control_plane]

  defp advisory_variant(%{level: :error}), do: "error"
  defp advisory_variant(%{level: :warning}), do: "warning"
  defp advisory_variant(%{level: :ok}), do: "success"
  defp advisory_variant(_advisory), do: "ghost"

  defp fallback_label(%{fallback_channel_id: nil}, _index), do: "none"

  defp fallback_label(%{fallback_channel_id: id}, index) do
    case Map.get(index, to_string(id)) do
      nil -> "channel #{id}"
      channel -> channel.name
    end
  end

  defp fallback_label(_channel, _index), do: "none"

  defp policy_name(%{escalation_policy: %{name: name}}) when is_binary(name), do: name
  defp policy_name(_route), do: "(policy unavailable)"

  defp schedule_name(%{schedule: %{name: name}}) when is_binary(name), do: name
  defp schedule_name(_route), do: "always"

  defp policy_steps(%{steps: steps}) when is_list(steps), do: Enum.sort_by(steps, & &1.step_number)
  defp policy_steps(_policy), do: []

  defp step_channel_ids(%{step_channels: links}) when is_list(links) do
    Enum.map(links, &to_string(&1.channel_id))
  end

  defp step_channel_ids(_step), do: []

  defp channel_label(nil, _index), do: "-"

  defp channel_label(id, index) do
    case Map.get(index, to_string(id)) do
      nil -> "channel #{id}"
      channel -> channel.name
    end
  end

  defp channel_badge_variant(id, index) do
    case Map.get(index, to_string(id)) do
      nil -> "error"
      %{enabled: false} -> "warning"
      %{execution_route: :edge_agent} -> "warning"
      _channel -> "ghost"
    end
  end

  # A step referencing a disabled or missing channel is flagged where the
  # operator reads the ladder, not only when a delivery later records
  # `channel_disabled`.
  defp degraded_channels(step, index) do
    step
    |> step_channel_ids()
    |> Enum.flat_map(fn id ->
      case Map.get(index, id) do
        nil -> ["channel #{id} (missing)"]
        %{enabled: false, name: name} -> ["#{name} (disabled)"]
        _channel -> []
      end
    end)
  end

  defp alert_title(%{alert_snapshot: %{} = snapshot}) do
    snapshot
    |> Map.get("title", Map.get(snapshot, :title, "(no title)"))
    |> to_string()
    |> Presentation.truncate(90)
  end

  defp alert_title(_delivery), do: "(no snapshot)"

  defp alert_severity(%{alert_snapshot: %{} = snapshot}) do
    snapshot
    |> Map.get("severity", Map.get(snapshot, :severity, "-"))
    |> to_string()
  end

  defp alert_severity(_delivery), do: "-"

  defp humanize_delay(nil), do: "0s"
  defp humanize_delay(seconds) when seconds < 60, do: "#{seconds}s"
  defp humanize_delay(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp humanize_delay(seconds), do: "#{div(seconds, 3600)}h"

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp parse_int(_value), do: 0

  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]
end
