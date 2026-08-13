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

  attr :entries, :list, required: true
  attr :can_manage, :boolean, default: false

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
        </div>

        <.verdict_rollup rollup={entry.rollup} />
      </li>
    </ul>
    """
  end

  attr :state, :atom, required: true

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

  attr :rollup, :list, default: nil

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

  attr :form, :map, required: true
  attr :errors, :list, default: []
  attr :mode, :atom, required: true
  attr :scope_count, :integer, default: nil
  attr :builder, :map, required: true
  attr :builder_in_sync, :boolean, default: true
  attr :save_error, :string, default: nil
  attr :vantage_points, :list, default: []
  attr :agents, :list, default: []

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
        errors={Enum.filter(@errors, fn {field, _msg} -> field == "vantage_points" end)}
      />
    </.form>
    """
  end

  attr :form, :map, required: true
  attr :scope_count, :integer, default: nil
  attr :builder, :map, required: true
  attr :builder_in_sync, :boolean, default: true

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

  attr :rows, :list, required: true
  attr :agents, :list, required: true
  attr :errors, :list, default: []

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

  attr :expected, :string, default: nil

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

  attr :errors, :list, default: []

  def field_errors(assigns) do
    ~H"""
    <ul :if={@errors != []} class="space-y-1">
      <li :for={{_field, message} <- @errors} class="text-xs text-rose-400">{message}</li>
    </ul>
    """
  end

  attr :rules, :list, required: true
  attr :columns, :list, required: true
  attr :mode, :atom, required: true
  attr :confirm_regenerate, :boolean, default: false
  attr :error, :string, default: nil

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

  attr :rule, :map, required: true
  attr :columns, :list, required: true
  attr :first, :boolean, default: false
  attr :last, :boolean, default: false

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
  defp grid_style(columns) do
    "grid-template-columns: repeat(#{length(columns)}, minmax(7rem, 1fr)) 10rem 10rem 8rem 6rem"
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
