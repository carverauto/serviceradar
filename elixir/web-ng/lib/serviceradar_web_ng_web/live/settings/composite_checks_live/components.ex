defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Components do
  @moduledoc """
  Presentation for the composite checks index and builder.

  Colour keys on `status`, never on `verdict`. Verdict slugs are operator
  authored, so any styling keyed to them is wrong on the next deployment;
  `status` is the fixed `healthy | degraded | down | unknown` enum and is what
  rollups, badges, and bars are safe to switch on.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.CompositeChecks.Rollup
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.RuleTable

  attr(:entries, :list, required: true)
  attr(:can_manage, :boolean, default: false)

  def check_list(assigns) do
    ~H"""
    <ul class="space-y-2">
      <li
        :for={entry <- @entries}
        class="rounded-sr-control border border-sr-border bg-sr-surface p-4"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <.link
                :if={@can_manage}
                navigate={~p"/settings/networks/composite-checks/#{entry.check.id}/edit"}
                class="truncate text-sm font-medium text-sr-ink hover:underline"
              >
                {entry.check.name}
              </.link>
              <span :if={!@can_manage} class="truncate text-sm font-medium text-sr-ink">
                {entry.check.name}
              </span>
              <.state_badge state={entry.check.state} />
            </div>

            <p class="mt-1 truncate font-mono text-xs text-sr-ink-muted">
              {entry.check.scope_query}
            </p>

            <p class="mt-1 text-xs text-sr-ink-muted">
              <span :if={entry.scope_count}>{entry.scope_count} devices in scope</span>
              <span :if={is_nil(entry.scope_count)}>Scope size unavailable</span>
            </p>
          </div>

          <div :if={@can_manage} class="flex shrink-0 flex-wrap items-center justify-end gap-2">
            <button
              :if={entry.check.state == :enabled}
              type="button"
              phx-click="disable"
              phx-value-id={entry.check.id}
              class="rounded-sr-control border border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
            >
              Disable
            </button>
            <button
              type="button"
              phx-click="delete_check"
              phx-value-id={entry.check.id}
              data-confirm={"Remove #{entry.check.name}? Saved verdicts for this check will be deleted."}
              class="rounded-sr-control border border-rose-500/40 px-3 py-1.5 text-xs text-rose-400 hover:bg-rose-500/5"
            >
              Remove
            </button>
          </div>
        </div>

        <.verdict_rollup rollup={entry.rollup} />
      </li>
    </ul>
    """
  end

  attr(:state, :atom, required: true)

  def state_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 rounded-sr-control px-2 py-0.5 text-xs font-medium",
      @state == :enabled && "bg-emerald-500/10 text-emerald-400",
      @state == :draft && "bg-amber-500/10 text-amber-400",
      @state == :disabled && "bg-sr-surface-muted text-sr-ink-muted"
    ]}>
      {@state}
    </span>
    """
  end

  attr(:rollup, :list, default: nil)

  def verdict_rollup(assigns) do
    assigns = assign(assigns, :total, Rollup.total(assigns.rollup))

    ~H"""
    <p :if={is_nil(@rollup)} class="mt-3 text-xs text-sr-ink-muted">
      Not yet evaluated. Enable the check to start recording verdicts.
    </p>

    <div :if={@rollup} class="mt-3 space-y-2">
      <div class="flex h-1.5 overflow-hidden rounded-full bg-sr-surface-muted">
        <span
          :for={entry <- @rollup}
          class={["block", status_bar_class(entry.status)]}
          style={"width: #{percent(entry.count, @total)}%"}
          title={"#{entry.verdict}: #{entry.count}"}
        />
      </div>

      <ul class="flex flex-wrap gap-x-4 gap-y-1">
        <li :for={entry <- @rollup} class="flex items-center gap-1.5 text-xs">
          <span class={["size-1.5 rounded-full", status_bar_class(entry.status)]} />
          <span class="font-mono text-sr-ink">{entry.verdict}</span>
          <span class="text-sr-ink-muted">{entry.count}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:errors, :list, default: [])
  attr(:mode, :atom, required: true)
  attr(:check_id, :any, default: nil)
  attr(:state, :atom, default: nil)
  attr(:scope_count, :integer, default: nil)
  attr(:builder, :map, required: true)
  attr(:builder_in_sync, :boolean, default: true)
  attr(:save_error, :string, default: nil)
  attr(:vantage_points, :list, default: [])
  attr(:coverage_intervals, :map, default: %{})
  attr(:device_facts, :list, default: [])
  attr(:fact_key_suggestions, :list, default: [])
  attr(:agents, :list, default: [])

  def check_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:form}
      id="composite-check-form"
      phx-change="validate"
      phx-submit="save"
      class="space-y-6"
    >
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold text-sr-ink">
            {if @mode == :new, do: "New Composite Check", else: "Edit Composite Check"}
          </h1>
          <p class="mt-1 text-sm text-sr-ink-muted">
            Scope the devices this check answers for, then say what each vantage point should see.
          </p>
        </div>
        <div class="flex shrink-0 gap-2">
          <.button navigate={~p"/settings/networks/composite-checks"}>Cancel</.button>
          <button
            :if={@mode == :edit and @state == :enabled}
            type="button"
            phx-click="disable"
            phx-value-id={@check_id}
            class="rounded-sr-control border border-sr-border px-3 py-1.5 text-sm text-sr-ink-muted hover:text-sr-ink"
          >
            Disable
          </button>
          <button
            :if={@mode == :edit and not is_nil(@check_id)}
            type="button"
            phx-click="delete_check"
            phx-value-id={@check_id}
            data-confirm="Remove this composite check? Saved verdicts will be deleted."
            class="rounded-sr-control border border-rose-500/40 px-3 py-1.5 text-sm text-rose-400 hover:bg-rose-500/5"
          >
            Remove
          </button>
          <.button variant="primary">Save</.button>
        </div>
      </div>

      <div :if={@save_error} class="rounded-sr-control border border-rose-500/40 bg-rose-500/5 p-3">
        <p class="text-sm text-rose-400">{@save_error}</p>
      </div>

      <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
        <.input type="text" name="form[name]" value={@form["name"]} label="Name" />
        <.input
          type="text"
          name="form[description]"
          value={@form["description"]}
          label="Description"
        />
        <.input
          type="number"
          name="form[evaluation_interval_seconds]"
          value={@form["evaluation_interval_seconds"]}
          label="Evaluation interval (seconds)"
        />
        <.input
          type="checkbox"
          name="form[write_canonical_availability]"
          value={@form["write_canonical_availability"]}
          checked={@form["write_canonical_availability"] in [true, "true"]}
          label="Write canonical device availability"
        />
        <p class="text-xs text-sr-ink-muted">
          Off by default. When on, a healthy verdict sets the device available bit and a
          down verdict clears it. Armis northbound still exports this check's verdict as
          its own custom field. Use Availability Sources to pick which sweep agent owns
          the canonical bit.
        </p>
        <.field_errors errors={@errors} />
      </section>

      <.scope_panel
        form={@form}
        scope_count={@scope_count}
        builder={@builder}
        builder_in_sync={@builder_in_sync}
      />

      <.vantage_points
        rows={@vantage_points}
        agents={@agents}
        coverage_intervals={@coverage_intervals}
        errors={Enum.filter(@errors, fn {field, _msg} -> field == "vantage_points" end)}
      />

      <.device_facts
        rows={@device_facts}
        key_suggestions={@fact_key_suggestions}
        errors={Enum.filter(@errors, fn {field, _msg} -> field == "device_facts" end)}
      />
    </.form>
    """
  end

  attr(:form, :map, required: true)
  attr(:scope_count, :integer, default: nil)
  attr(:builder, :map, required: true)
  attr(:builder_in_sync, :boolean, default: true)

  def scope_panel(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div>
        <h2 class="text-sm font-semibold text-sr-ink">Scope</h2>
        <p class="text-xs text-sr-ink-muted">Which devices this check runs against.</p>
      </div>

      <.input
        type="text"
        name="form[scope_query]"
        value={@form["scope_query"]}
        label="SRQL"
        class="w-full rounded-sr-control border border-sr-border bg-sr-surface-muted px-3 py-2 font-mono text-sm text-sr-ink"
      />

      <p :if={@scope_count} class="text-xs text-sr-ink-muted">
        <span class="font-medium text-sr-ink">{@scope_count}</span>
        devices in scope · membership refreshes as inventory syncs
      </p>

      <div
        :if={!@builder_in_sync}
        class="rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3"
      >
        <p class="text-xs text-amber-400">
          This query uses syntax the visual builder cannot represent, so the filter rows below are
          not editing it. The SRQL above is what will be saved.
        </p>
      </div>

      <div :if={@builder_in_sync} class="space-y-2">
        <p class="text-xs font-medium text-sr-ink-muted">Filters</p>
        <div
          :for={{filter, index} <- Enum.with_index(Map.get(@builder, "filters", []))}
          class="flex flex-wrap items-center gap-2"
        >
          <input
            type="text"
            name={"builder[filters][#{index}][field]"}
            value={filter["field"]}
            aria-label="Filter field"
            class="w-40 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
          />
          <select
            name={"builder[filters][#{index}][op]"}
            aria-label="Filter operator"
            class="rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
          >
            <option
              :for={op <- ~w(equals not_equals contains not_contains)}
              value={op}
              selected={filter["op"] == op}
            >
              {String.replace(op, "_", " ")}
            </option>
          </select>
          <input
            type="text"
            name={"builder[filters][#{index}][value]"}
            value={filter["value"]}
            aria-label="Filter value"
            class="w-48 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
          />
          <button
            type="button"
            phx-click="remove_filter"
            phx-value-index={index}
            class="text-sr-ink-muted hover:text-sr-ink"
            aria-label="Remove filter"
          >
            <.icon name="hero-x-mark-mini" class="size-4" />
          </button>
        </div>

        <button
          type="button"
          phx-click="add_filter"
          class="rounded-sr-control border border-dashed border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
        >
          + Add filter
        </button>
      </div>
    </section>
    """
  end

  attr(:rows, :list, required: true)
  attr(:errors, :list, default: [])
  attr(:key_suggestions, :list, default: [])

  @doc """
  Device facts: the third input kind, alongside the vantage points.

  A vantage point answers "can this agent reach it". A device fact answers "does
  the device carry the configuration that is supposed to make it unreachable" —
  that answer arrives as a boolean written through the device fact API. Without it a
  check can only say a device *is* blocked, never that it is blocked *because it
  is configured to be*, which is the difference between `isolated_verified` and
  `isolated_unenforced` in the generated table.
  """
  def device_facts(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div>
        <h2 class="text-sm font-semibold text-sr-ink">Device facts</h2>
        <p class="text-xs text-sr-ink-muted">
          Optional. A boolean the device carries in its metadata — written through the device fact
          API by whatever validates your device configuration — so the check can tell enforced
          isolation from incidental isolation.
        </p>
      </div>

      <%!-- A combobox, not a select. The key an operator wants is usually the one
      their validator is about to start writing, so it does not exist yet and a
      closed list would make the common case impossible. The datalist offers the
      keys that DO exist and hold booleans, which is what catches a typo. --%>
      <datalist id="device-fact-key-options">
        <option :for={suggestion <- @key_suggestions} value={suggestion.key}>
          {"#{suggestion.devices} device#{if suggestion.devices == 1, do: "", else: "s"}"}
        </option>
      </datalist>

      <div :for={{row, index} <- Enum.with_index(@rows)} class="flex flex-wrap items-center gap-2">
        <input
          type="text"
          name={"device_facts[#{index}][path]"}
          value={row["path"]}
          list="device-fact-key-options"
          placeholder="metadata key, e.g. acl_enforced"
          aria-label="Metadata key"
          class="min-w-64 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 font-mono text-sm text-sr-ink"
        />

        <span class="text-xs text-sr-ink-muted">is a boolean</span>

        <input
          type="text"
          name={"device_facts[#{index}][max_age_seconds]"}
          value={row["max_age_seconds"]}
          placeholder="max age (s), optional"
          aria-label="Fact max age seconds"
          class="w-40 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
        />

        <button
          type="button"
          phx-click="remove_device_fact"
          phx-value-index={index}
          class="ml-auto text-sr-ink-muted hover:text-sr-ink"
          aria-label="Remove device fact"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <button
        type="button"
        phx-click="add_device_fact"
        class="rounded-sr-control border border-dashed border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
      >
        + Add device fact
      </button>

      <.field_errors errors={@errors} />

      <p :if={@rows != [] and @key_suggestions != []} class="text-xs text-sr-ink-muted">
        Existing boolean keys are offered as you type. A key your validator has not written yet
        will not appear — type it anyway.
      </p>

      <p :if={@rows != []} class="text-xs text-sr-ink-muted">
        Leave max age blank to trust the stored value however old it is. Set it and the fact
        resolves <span class="font-mono">unknown</span>
        unless the write recorded provenance inside that window — which is what stops a check
        certifying a device on a configuration nobody has confirmed lately.
      </p>
    </section>
    """
  end

  attr(:rows, :list, required: true)
  attr(:agents, :list, required: true)
  attr(:errors, :list, default: [])
  # agent_id => slowest covering sweep interval in seconds. Empty on :new,
  # where no inputs exist yet and there is nothing to compare against.
  attr(:coverage_intervals, :map, default: %{})

  def vantage_points(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div>
        <h2 class="text-sm font-semibold text-sr-ink">Vantage points</h2>
        <p class="text-xs text-sr-ink-muted">
          Each agent below is asked the same question. Set what you expect it to see.
        </p>
      </div>

      <div :for={{row, index} <- Enum.with_index(@rows)} class="flex flex-wrap items-center gap-2">
        <select
          name={"vantage_points[#{index}][agent_id]"}
          aria-label="Agent"
          class="min-w-56 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
        >
          <option value="">Select an agent…</option>
          <option :for={agent <- @agents} value={agent.uid} selected={row["agent_id"] == agent.uid}>
            {agent_label(agent)}
          </option>
        </select>

        <span class="text-xs text-sr-ink-muted">should see</span>

        <select
          name={"vantage_points[#{index}][expected]"}
          aria-label="Expectation"
          class="rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
        >
          <option value="available" selected={row["expected"] == "available"}>available</option>
          <option value="blocked" selected={row["expected"] == "blocked"}>blocked</option>
        </select>

        <.vantage_role_badge expected={row["expected"]} />

        <span class="text-xs text-sr-ink-muted">using results younger than</span>

        <input
          type="text"
          inputmode="numeric"
          name={"vantage_points[#{index}][max_age_seconds]"}
          value={row["max_age_seconds"]}
          aria-label="Freshness window in seconds"
          class="w-24 rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sm text-sr-ink"
        />

        <span class="text-xs text-sr-ink-muted">seconds</span>

        <p
          :if={stale_window?(row, @coverage_intervals)}
          class="basis-full rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3 text-xs text-amber-400"
          data-vantage-stale-window={row["agent_id"]}
        >
          <span class="font-medium">
            This window is shorter than the sweep that feeds it.
          </span>
          The slowest group covering this agent runs every {covering_interval(
            row,
            @coverage_intervals
          )}s, so between runs every device resolves unknown and the check reports no results for
          this vantage point. Use at least that long.
        </p>

        <button
          type="button"
          phx-click="remove_vantage_point"
          phx-value-index={index}
          class="ml-auto text-sr-ink-muted hover:text-sr-ink"
          aria-label="Remove vantage point"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <button
        type="button"
        phx-click="add_vantage_point"
        class="rounded-sr-control border border-dashed border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
      >
        + Add vantage point
      </button>

      <.field_errors errors={@errors} />

      <div
        :if={!has_witness?(@rows) and length(@rows) > 1}
        class="rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3"
      >
        <p class="text-xs text-amber-400">
          <span class="font-medium">At least one agent must be a liveness witness.</span>
          Without one, a powered-off device is indistinguishable from a perfectly isolated one, so
          this check cannot be enabled.
        </p>
      </div>
    </section>
    """
  end

  # A freshness window shorter than the sweep interval feeding it cannot ever be
  # satisfied for the whole scope: between two runs of an hourly sweep, a
  # 15-minute window leaves 45 minutes where every device resolves unknown. This
  # is the check that makes that visible while it is still editable, rather than
  # as an unexplained "0 of N devices have results" on the readiness panel.
  defp stale_window?(row, coverage_intervals) do
    with interval when is_integer(interval) <- covering_interval(row, coverage_intervals),
         max_age when is_integer(max_age) <- parse_seconds(row["max_age_seconds"]) do
      max_age < interval
    else
      _ -> false
    end
  end

  defp covering_interval(row, coverage_intervals) do
    Map.get(coverage_intervals, row["agent_id"])
  end

  defp parse_seconds(value) when is_integer(value), do: value

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp parse_seconds(_value), do: nil

  attr(:expected, :string, default: nil)

  def vantage_role_badge(assigns) do
    ~H"""
    <span
      :if={@expected == "available"}
      class="rounded-sr-control bg-emerald-500/10 px-2 py-0.5 font-mono text-[10px] uppercase tracking-wide text-emerald-400"
    >
      liveness witness
    </span>
    <span
      :if={@expected == "blocked"}
      class="rounded-sr-control bg-sr-surface-muted px-2 py-0.5 font-mono text-[10px] uppercase tracking-wide text-sr-ink-muted"
    >
      isolation probe
    </span>
    """
  end

  defp has_witness?(rows), do: Enum.any?(rows, &(&1["expected"] == "available"))

  defp agent_label(agent) do
    case {agent.name, agent.host} do
      {name, host} when is_binary(name) and name != "" and is_binary(host) and host != "" ->
        "#{name} · #{host}"

      {name, _host} when is_binary(name) and name != "" ->
        name

      _ ->
        agent.uid
    end
  end

  attr(:errors, :list, default: [])

  def field_errors(assigns) do
    ~H"""
    <ul :if={@errors != []} class="space-y-1">
      <li :for={{_field, message} <- @errors} class="text-xs text-rose-400">{message}</li>
    </ul>
    """
  end

  attr(:rules, :list, required: true)
  attr(:columns, :list, required: true)
  attr(:mode, :atom, required: true)
  attr(:confirm_regenerate, :boolean, default: false)
  attr(:error, :string, default: nil)

  @doc """
  The decision table: rules in evaluation order, first match wins.

  Rendered outside the check form rather than inside it. Rule edits persist
  immediately against their own resource, and a form inside a form is invalid
  HTML — the browser drops the inner one and the row silently stops submitting.
  """
  def rule_table(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Verdict rules</h2>
          <p class="text-xs text-sr-ink-muted">
            Evaluated top to bottom; the first row whose cells all match wins.
          </p>
        </div>
        <button
          :if={@mode == :edit}
          type="button"
          phx-click="generate_rules"
          class="rounded-sr-control border border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
        >
          Generate from expectations
        </button>
      </div>

      <p :if={@mode == :new} class="text-xs text-sr-ink-muted">
        Save the check to build its decision table. Rules match on vantage point keys, which do not
        exist until the vantage points are saved.
      </p>

      <div
        :if={@confirm_regenerate}
        class="space-y-2 rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3"
      >
        <p class="text-xs text-amber-400">
          Generating replaces every rule below with a fresh table. Any edits to verdicts,
          descriptions, statuses, or matching will be lost.
        </p>
        <div class="flex gap-2">
          <button
            type="button"
            phx-click="confirm_regenerate"
            class="rounded-sr-control border border-amber-500/40 px-3 py-1 text-xs text-amber-400"
          >
            Replace the table
          </button>
          <button
            type="button"
            phx-click="cancel_regenerate"
            class="rounded-sr-control border border-sr-border px-3 py-1 text-xs text-sr-ink-muted"
          >
            Keep my edits
          </button>
        </div>
      </div>

      <p :if={@error} class="text-xs text-rose-400">{@error}</p>

      <p :if={@mode == :edit and @rules == []} class="text-xs text-sr-ink-muted">
        No rules yet. Generate a table from the vantage point expectations, or add rules once the
        vantage points are saved.
      </p>

      <div :if={@rules != []} class="overflow-x-auto">
        <div class="min-w-[52rem] space-y-1 text-xs">
          <div
            class={["grid gap-2 px-1 text-sr-ink-muted", "font-medium"]}
            style={grid_style(@columns)}
          >
            <span :for={column <- @columns}>{column.label}</span>
            <span>Verdict</span>
            <span>Label</span>
            <span>Status</span>
            <span class="sr-only">Actions</span>
          </div>

          <.rule_row
            :for={rule <- @rules}
            rule={rule}
            columns={@columns}
            first={rule == List.first(authored(@rules))}
            last={rule == List.last(authored(@rules))}
          />
        </div>
      </div>
    </section>
    """
  end

  attr(:rule, :map, required: true)
  attr(:columns, :list, required: true)
  attr(:first, :boolean, default: false)
  attr(:last, :boolean, default: false)

  # Each row is its own form: rule edits persist immediately against their own
  # resource, and the whole table sits outside the check form because a form
  # nested in a form is invalid HTML — the browser drops the inner one and the
  # row silently stops submitting.
  defp rule_row(assigns) do
    ~H"""
    <form
      id={rule_form_id(@rule)}
      phx-change="update_rule"
      class={[
        "grid items-center gap-2 rounded-sr-control border border-sr-border px-1 py-1.5",
        @rule.catch_all && "bg-sr-surface-muted"
      ]}
      style={grid_style(@columns)}
    >
      <input type="hidden" name="rule_id" value={@rule.id} />

      <div :for={column <- @columns}>
        <select
          :if={!@rule.catch_all}
          name={"match[#{column.key}]"}
          aria-label={"#{column.label} match"}
          class="w-full rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sr-ink"
        >
          <option
            :for={{value, label} <- column.options}
            value={value}
            selected={RuleTable.cell_value(@rule.match, column) == value}
          >
            {label}
          </option>
        </select>
        <span :if={@rule.catch_all} class="px-2 text-sr-ink-muted">any</span>
      </div>

      <input
        type="text"
        name="verdict"
        value={@rule.verdict}
        aria-label="Verdict"
        class="w-full rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 font-mono text-sr-ink"
      />

      <input
        type="text"
        name="verdict_label"
        value={@rule.verdict_label}
        aria-label="Verdict label"
        class="w-full rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sr-ink"
      />

      <div>
        <select
          :if={!@rule.catch_all}
          name="status"
          aria-label="Status"
          class="w-full rounded-sr-control border border-sr-border bg-sr-surface-muted px-2 py-1 text-sr-ink"
        >
          <option
            :for={status <- RuleTable.statuses()}
            value={status}
            selected={@rule.status == status}
          >
            {status}
          </option>
        </select>
        <span :if={@rule.catch_all} class="px-2 text-sr-ink-muted">unknown</span>
      </div>

      <div :if={!@rule.catch_all} class="flex items-center justify-end gap-1">
        <button
          type="button"
          phx-click="move_rule"
          phx-value-id={@rule.id}
          phx-value-direction="up"
          disabled={@first}
          aria-label="Move rule up"
          class="text-sr-ink-muted hover:text-sr-ink disabled:opacity-30"
        >
          <.icon name="hero-arrow-up-mini" class="size-4" />
        </button>
        <button
          type="button"
          phx-click="move_rule"
          phx-value-id={@rule.id}
          phx-value-direction="down"
          disabled={@last}
          aria-label="Move rule down"
          class="text-sr-ink-muted hover:text-sr-ink disabled:opacity-30"
        >
          <.icon name="hero-arrow-down-mini" class="size-4" />
        </button>
        <button
          type="button"
          phx-click="delete_rule"
          phx-value-id={@rule.id}
          aria-label="Delete rule"
          class="text-sr-ink-muted hover:text-rose-400"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <span
        :if={@rule.catch_all}
        class="text-right text-[10px] uppercase tracking-wide text-sr-ink-muted"
      >
        fallback
      </span>
    </form>
    """
  end

  # The column count is the number of inputs, so the track list is built rather
  # than declared: a Tailwind class cannot carry a runtime-sized repeat().
  # Verdict slugs run long — `inverted_reachability` is 21 mono characters — and
  # a column that truncates the value reads as data loss even though the input
  # still holds it.
  defp grid_style(columns) do
    "grid-template-columns: repeat(#{length(columns)}, minmax(7rem, 1fr)) 13rem 12rem 8rem 6rem"
  end

  attr(:entries, :list, default: [])
  attr(:mode, :atom, required: true)

  @doc """
  The sweeps that actually feed each vantage point, read-only.

  A vantage point maps to zero or more sweep groups, not to one scan profile:
  an empty `SweepGroup.agent_ids` means every agent in the device partition,
  while a non-empty array is a fixed scanner subset. Naming one group as the
  check's profile would misstate which ports are probed.
  """
  def sweep_context(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Sweep coverage</h2>
          <p class="text-xs text-sr-ink-muted">
            Composite checks read what these sweeps produce; they never probe.
          </p>
        </div>
        <.link
          navigate={~p"/settings/networks"}
          class="shrink-0 text-xs text-sr-ink-muted hover:text-sr-ink hover:underline"
        >
          Edit in sweep administration
        </.link>
      </div>

      <p :if={@mode == :new} class="text-xs text-sr-ink-muted">
        Save the check to see which sweeps feed its vantage points.
      </p>

      <p :if={@mode == :edit and @entries == []} class="text-xs text-sr-ink-muted">
        No vantage points yet, so nothing feeds this check.
      </p>

      <div :for={entry <- @entries} class="space-y-1" data-sweep-input={entry.key}>
        <p class="flex flex-wrap items-center gap-2 text-xs">
          <span class="font-mono text-sr-ink">{entry.label}</span>
          <span class="text-sr-ink-muted">{"in partition #{entry.partition}"}</span>
        </p>

        <p
          :if={entry.groups == []}
          class="rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3 text-xs text-amber-400"
          data-sweep-uncovered={entry.agent_id}
        >
          No sweep group covers this agent, so this vantage point will resolve unknown for every
          device and the check will stay inconclusive.
        </p>

        <ul :if={entry.groups != []} class="space-y-1">
          <li
            :for={group <- entry.groups}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-sr-control border border-sr-border px-3 py-2 text-xs"
            data-sweep-group={group.id}
          >
            <.link
              navigate={~p"/settings/networks/groups/#{group.id}"}
              class="font-medium text-sr-ink hover:underline"
            >
              {group.name}
            </.link>

            <span class="text-sr-ink-muted">
              {if group.assigned?, do: "selected for this agent", else: "all agents in partition"}
            </span>

            <span :if={group.interval} class="text-sr-ink-muted">every {group.interval}</span>

            <span :if={group.modes != []} class="font-mono text-sr-ink-muted">
              {Enum.join(group.modes, ", ")}
            </span>

            <span :if={group.ports != []} class="font-mono text-sr-ink-muted">
              {"ports #{ports_summary(group.ports)}"}
            </span>

            <span :if={group.ports == []} class="text-sr-ink-muted">no ports configured</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  @ports_shown 12

  # A profile can carry hundreds of ports. The full list is sweep
  # administration's to render; here it is context, and an unbounded list would
  # push everything else off the panel.
  defp ports_summary(ports) do
    case Enum.split(ports, @ports_shown) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> "#{Enum.join(shown, ", ")} +#{length(rest)} more"
    end
  end

  attr(:readiness, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:mode, :atom, required: true)
  attr(:state, :atom, default: nil)
  attr(:labels, :map, default: %{})

  @doc """
  Whether the check is safe to enable, and what stops it.

  Coverage rows show the vantage point's label *and* its agent id. The blocking
  and warning messages are composed in `Readiness` and name the agent id, which
  is the durable handle an operator carries to sweep administration; showing
  both here is what connects that prose to the name they picked in the builder.

  Every problem shown here is produced by `Readiness.check/2` — the same call the
  `:enable` action validates with. The panel renders the report; it never
  re-derives a rule, so it cannot disagree with the gate.
  """
  def readiness_panel(assigns) do
    assigns = assign(assigns, :coverage_gap?, coverage_gap?(assigns.readiness))

    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Readiness</h2>
          <p class="text-xs text-sr-ink-muted">
            Whether this check can produce meaningful verdicts before you enable it.
          </p>
        </div>

        <div :if={@mode == :edit} class="flex shrink-0 items-center gap-2">
          <span class="text-xs text-sr-ink-muted">State</span>
          <.state_badge state={@state} />
        </div>
      </div>

      <p :if={@mode == :new} class="text-xs text-sr-ink-muted">
        Save the check to see whether it is ready to enable.
      </p>

      <div :if={@mode == :edit} class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="check_readiness"
          class="rounded-sr-control border border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
        >
          Check readiness
        </button>
      </div>

      <p :if={@error} class="text-xs text-rose-400">{@error}</p>

      <div :if={@readiness} class="space-y-2">
        <p
          :if={@readiness.blocking == [] and @readiness.warnings == []}
          class="text-xs text-emerald-400"
        >
          Every vantage point has coverage and a liveness witness is declared.
        </p>

        <ul :if={@readiness.blocking != []} class="space-y-1">
          <li
            :for={problem <- @readiness.blocking}
            class="rounded-sr-control border border-rose-500/40 bg-rose-500/5 p-3 text-xs text-rose-400"
            data-readiness-blocking={problem.code}
          >
            {problem.message}
          </li>
        </ul>

        <ul :if={@readiness.warnings != []} class="space-y-1">
          <li
            :for={problem <- @readiness.warnings}
            class="rounded-sr-control border border-amber-500/40 bg-amber-500/5 p-3 text-xs text-amber-400"
            data-readiness-warning={problem.code}
          >
            {problem.message}
          </li>
        </ul>

        <ul :if={@readiness.coverage != []} class="space-y-1">
          <li
            :for={row <- @readiness.coverage}
            class="flex flex-wrap items-center gap-2 text-xs"
            data-coverage-agent={row.agent_id}
            data-coverage-covered={row.covered}
            data-coverage-total={row.total}
          >
            <span class="text-sr-ink">{Map.get(@labels, row.input_key, row.agent_id)}</span>
            <span class="font-mono text-sr-ink-muted">{row.agent_id}</span>
            <span class="text-sr-ink-muted">
              {"#{row.covered} of #{row.total} devices in scope have fresh results"}
            </span>
          </li>
        </ul>
      </div>

      <form :if={@mode == :edit and @state != :enabled} phx-submit="enable" class="space-y-2">
        <label :if={@coverage_gap?} class="flex items-start gap-2 text-xs text-sr-ink-muted">
          <input type="checkbox" name="acknowledge_coverage_gap" value="true" class="mt-0.5" />
          <span>
            I understand a vantage point has no coverage and every device will evaluate as
            inconclusive until its sweep is running.
          </span>
        </label>

        <button
          type="submit"
          class="rounded-sr-control border border-sr-border px-3 py-1.5 text-xs text-sr-ink hover:bg-sr-surface-muted"
        >
          Enable
        </button>
      </form>
    </section>
    """
  end

  # The acknowledgement is offered only when a coverage gap is the *only* thing
  # blocking. A missing liveness witness is not acknowledgeable — it is a
  # correctness fault, not a timing one — and showing the checkbox alongside it
  # would promise an override the resource refuses, sending the operator to tick
  # a box that changes nothing.
  defp coverage_gap?(nil), do: false
  defp coverage_gap?(%{blocking: []}), do: false

  defp coverage_gap?(%{blocking: blocking}) do
    Enum.all?(blocking, &(&1.code == :no_coverage))
  end

  attr(:preview, :map, default: nil)
  attr(:error, :string, default: nil)
  attr(:mode, :atom, required: true)
  attr(:can_evaluate, :boolean, default: false)
  attr(:state, :atom, default: nil)

  @doc """
  What the check would decide, right now, for a sample of its scope.

  Runs the same evaluation the scheduled pass runs, so preview and production
  cannot disagree. Nothing is persisted and no verdict events are emitted.
  """
  def preview_panel(assigns) do
    ~H"""
    <section class="space-y-3 rounded-sr-control border border-sr-border bg-sr-surface p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">Preview</h2>
          <p class="text-xs text-sr-ink-muted">
            Evaluates the saved check over a sample of its scope. Nothing is recorded.
          </p>
        </div>
        <button
          :if={@mode == :edit and @can_evaluate}
          type="button"
          phx-click="run_preview"
          class="rounded-sr-control border border-sr-border px-3 py-1.5 text-xs text-sr-ink-muted hover:text-sr-ink"
        >
          Run preview
        </button>
      </div>

      <p :if={@mode == :new} class="text-xs text-sr-ink-muted">
        Save the check to preview it. The preview evaluates what is stored, not what is on screen,
        so it always agrees with the scheduled pass.
      </p>

      <p :if={@mode == :edit and !@can_evaluate} class="text-xs text-sr-ink-muted">
        Previewing a check requires the evaluate permission.
      </p>

      <p :if={@error} class="text-xs text-rose-400">{@error}</p>

      <div :if={@preview} class="space-y-3">
        <.preview_rollup preview={@preview} state={@state} />

        <p :if={@preview.rows == []} class="text-xs text-sr-ink-muted">
          No devices are in scope, so there is nothing to evaluate.
        </p>

        <ul :if={@preview.rows != []} class="space-y-2">
          <.preview_row :for={row <- @preview.rows} row={row} />
        </ul>
      </div>
    </section>
    """
  end

  attr(:preview, :map, required: true)
  attr(:state, :atom, default: nil)

  defp preview_rollup(assigns) do
    ~H"""
    <div class="space-y-2 rounded-sr-control border border-sr-border bg-sr-surface-muted p-3">
      <p class="text-xs text-sr-ink-muted">
        <span :if={@preview.total && @preview.sampled < @preview.total}>
          Sampled <span class="font-medium text-sr-ink">{@preview.sampled}</span>
          of {@preview.total} devices in scope.
        </span>
        <span :if={is_nil(@preview.total) or @preview.sampled >= (@preview.total || 0)}>
          Evaluated <span class="font-medium text-sr-ink">{@preview.sampled}</span> devices in scope.
        </span>
        <span :if={@state == :draft}>
          This check is a draft, so these counts come from the sample, not from stored verdicts.
        </span>
      </p>

      <ul class="flex flex-wrap gap-x-4 gap-y-1">
        <li :for={entry <- @preview.verdicts} class="flex items-center gap-1.5 text-xs">
          <span class={["size-1.5 rounded-full", status_bar_class(entry.status)]} />
          <span class="font-mono text-sr-ink">{entry.verdict}</span>
          <span class="text-sr-ink-muted">{entry.count}</span>
        </li>
      </ul>

      <p :if={@preview.unreachable > 0} class="text-xs text-amber-400">
        <span class="font-medium">{@preview.unreachable}</span>
        of these devices are visible from no vantage point. They cannot be counted as compliant:
        a powered-off device is unreachable from everywhere, exactly like a perfectly isolated one.
      </p>
    </div>
    """
  end

  attr(:row, :map, required: true)

  # The data-preview-* attributes are the addressable version of what this row
  # says. Every value it renders — a verdict, an expectation, a status — also
  # appears in the rule table and the vantage point selects above it, so a test
  # asserting on the visible text alone would pass without the preview having
  # rendered anything.
  defp preview_row(assigns) do
    ~H"""
    <li
      class="rounded-sr-control border border-sr-border p-3"
      data-preview-device={@row.device_uid}
      data-preview-ip={@row.device_ip}
      data-preview-verdict={@row.verdict}
      data-preview-status={@row.status}
    >
      <div class="flex flex-wrap items-center gap-2">
        <%!-- A new tab, not a navigation: the operator is mid-authoring, and the
        builder holds unsaved rule edits and a preview that would be lost. --%>
        <.link
          href={~p"/devices/#{@row.device_uid}"}
          target="_blank"
          rel="noopener noreferrer"
          class="font-mono text-xs text-sr-ink underline decoration-sr-border underline-offset-2 hover:decoration-sr-ink"
        >
          {@row.device_uid}
        </.link>
        <span :if={@row.device_ip} class="font-mono text-xs text-sr-ink-muted">
          {@row.device_ip}
        </span>
        <span class={["size-1.5 rounded-full", status_bar_class(@row.status)]} />
        <span class="font-mono text-xs text-sr-ink">{@row.verdict}</span>
      </div>

      <p :if={@row.explanation} class="mt-1 text-xs text-sr-ink-muted">{@row.explanation}</p>

      <ul class="mt-2 space-y-1">
        <li
          :for={input <- @row.inputs}
          class="flex flex-wrap items-center gap-2 text-xs"
          data-preview-input={input.key}
          data-preview-value={input.value}
          data-preview-age={input.age}
          data-preview-reason={input.reason}
        >
          <span class="text-sr-ink-muted">{input.label}</span>
          <span class={["font-mono", input.stale && "text-amber-400", !input.stale && "text-sr-ink"]}>
            {input.value}
          </span>
          <span :if={input.expected} class="text-sr-ink-muted">
            {"expected #{input.expected}"}
          </span>
          <span class="text-sr-ink-muted">{input.age}</span>
          <span :if={input.stale} class="text-amber-400">stale</span>
          <span :if={input.reason} class="font-mono text-sr-ink-muted">{input.reason}</span>
        </li>
      </ul>
    </li>
    """
  end

  defp rule_form_id(rule), do: "rule-form-#{rule.id}"

  defp authored(rules), do: Enum.reject(rules, & &1.catch_all)

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: Float.round(count / total * 100, 2)

  defp status_bar_class(:healthy), do: "bg-emerald-500"
  defp status_bar_class(:degraded), do: "bg-amber-500"
  defp status_bar_class(:down), do: "bg-rose-500"
  defp status_bar_class(_status), do: "bg-sr-ink-muted"
end
