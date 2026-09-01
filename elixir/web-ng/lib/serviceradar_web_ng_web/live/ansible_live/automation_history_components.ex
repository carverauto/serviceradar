defmodule ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryComponents do
  @moduledoc """
  Presentation-only components for Ansible operation history.

  Inputs are plain, allowlisted maps produced by `AutomationHistory`; these
  components never receive Ash resources containing credential or authority
  internals.
  """

  use ServiceRadarWebNGWeb, :html

  attr :bundle, :map, required: true
  attr :timezone, :string, default: "Etc/UTC"

  def operation_detail(assigns) do
    ~H"""
    <div id="secure-ansible-operation-detail" class="mx-auto w-full max-w-[96rem] space-y-6 p-6">
      <nav class=" text-sm" aria-label="Breadcrumb">
        <ul>
          <li><.link navigate={~p"/ansible/operations"}>Ansible operations</.link></li>
          <li>Operation {short_id(@bundle.operation.id)}</li>
        </ul>
      </nav>

      <header class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-2">
          <span class={state_badge_classes(@bundle.operation.state)}>
            {@bundle.operation.state}
          </span>
          <h1 class="text-2xl font-semibold">Ansible operation {short_id(@bundle.operation.id)}</h1>
          <p class="font-mono text-xs text-sr-muted break-all">{@bundle.operation.id}</p>
        </div>
        <.ui_button type="button" phx-click="refresh" size="sm" variant="neutral">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </.ui_button>
      </header>

      <.state_alert state={@bundle.operation.state} subject="Operation" />

      <section
        class="sr-ui-card card-border bg-sr-surface"
        aria-labelledby="operation-evidence-heading"
      >
        <div class="sr-ui-card-body gap-4">
          <div>
            <h2 id="operation-evidence-heading" class="sr-ui-card-title text-base">
              Immutable operation evidence
            </h2>
            <p class="text-sm text-sr-muted">
              Human authority and target evidence captured before controller dispatch.
            </p>
          </div>

          <div class="stats stats-vertical border border-sr-line lg:stats-horizontal">
            <.evidence_stat label="Action" value={@bundle.operation.action} mono />
            <.evidence_stat
              label="Human initiator"
              value={principal(@bundle.operation)}
              mono
            />
            <.evidence_stat label="Request source" value={@bundle.operation.request_source} />
            <.evidence_stat label="Mode" value={operation_mode(@bundle.operation)} />
          </div>

          <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
            <.evidence_card label="Target digest" value={@bundle.operation.target_digest} mono />
            <.evidence_time_card
              id={"ansible-operation-#{@bundle.operation.id}-created-at"}
              label="Created"
              value={@bundle.operation.inserted_at}
              timezone={@timezone}
            />
            <.evidence_time_card
              id={"ansible-operation-#{@bundle.operation.id}-started-at"}
              label="Started"
              value={@bundle.operation.started_at}
              timezone={@timezone}
            />
            <.evidence_time_card
              id={"ansible-operation-#{@bundle.operation.id}-ended-at"}
              label="Ended"
              value={@bundle.operation.ended_at}
              timezone={@timezone}
            />
          </div>

          <.diagnostics entries={@bundle.operation.diagnostics} subject="Operation" />
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="operation-executions-heading">
        <div>
          <h2 id="operation-executions-heading" class="text-lg font-semibold">
            Controller executions
          </h2>
          <p class="text-sm text-sr-muted">
            {length(@bundle.executions)} inventory-bound child execution{plural(@bundle.executions)}.
          </p>
        </div>

        <div
          :if={@bundle.executions == []}
          role="status"
          class={ui_alert_class("warning")}
          id="secure-operation-no-executions"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>No child execution evidence has been persisted for this operation.</span>
        </div>

        <.execution_card
          :for={execution <- @bundle.executions}
          execution={execution}
          timezone={@timezone}
        />
      </section>
    </div>
    """
  end

  attr :execution, :map, required: true
  attr :timezone, :string, required: true

  defp execution_card(assigns) do
    ~H"""
    <article
      id={"secure-execution-#{@execution.id}"}
      class="sr-ui-card card-border bg-sr-surface"
      data-testid="secure-ansible-execution"
    >
      <div class="sr-ui-card-body gap-5">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="sr-ui-card-title text-base">Execution {short_id(@execution.id)}</h3>
              <span class={state_badge_classes(@execution.state)}>{@execution.state}</span>
            </div>
            <p class="mt-1 font-mono text-xs text-sr-muted break-all">{@execution.id}</p>
          </div>
          <div class="text-right text-sm">
            <p class="font-medium">{controller_name(@execution.controller)}</p>
            <p class="font-mono text-xs text-sr-muted break-all">
              {@execution.controller.id}
            </p>
          </div>
        </header>

        <.state_alert state={@execution.state} subject="Execution" />

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          <.evidence_card label="Inventory ID" value={@execution.inventory_id} mono />
          <.evidence_card label="Job template ID" value={@execution.job_template_id} mono />
          <.evidence_card label="Project ID" value={@execution.project_id} mono />
          <.evidence_card
            label="Execution environment ID"
            value={@execution.execution_environment_id}
            mono
          />
          <.evidence_card label="Project revision" value={@execution.scm_revision} mono />
          <.evidence_card label="Content digest" value={@execution.content_sha256} mono />
          <.evidence_card label="Host limit" value={@execution.host_limit} mono />
          <.evidence_card label="Check mode" value={yes_no(@execution.check_mode)} />
          <.evidence_card label="Dispatch ID" value={@execution.dispatch_id} mono />
          <.evidence_card label="Snapshot digest" value={@execution.snapshot_digest} mono />
          <.evidence_card
            label="AWX job (controller-local)"
            value={@execution.awx_job_id || "Not bound"}
            mono
          />
          <.evidence_time_card
            id={"ansible-execution-#{@execution.id}-started-at"}
            label="Started"
            value={@execution.started_at}
            timezone={@timezone}
          />
          <.evidence_time_card
            id={"ansible-execution-#{@execution.id}-ended-at"}
            label="Ended"
            value={@execution.ended_at}
            timezone={@timezone}
          />
        </div>

        <div
          :if={@execution.scope_verified_at}
          role="status"
          class={ui_alert_class("success")}
          data-testid="scope-proof-verified"
        >
          <.icon name="hero-shield-check" class="size-5" />
          <div>
            <p class="font-medium">Exact controller scope verified</p>
            <p class="text-sm">
              AWX job, inventory, literal limit, immutable revision, execution environment, credentials,
              dispatch markers, and returned host IDs matched at
              <.user_time
                id={"ansible-execution-#{@execution.id}-scope-verified-at"}
                value={@execution.scope_verified_at}
                timezone={@timezone}
                style={:compact}
              />.
            </p>
          </div>
        </div>

        <div
          :if={is_nil(@execution.scope_verified_at)}
          role="status"
          class={ui_alert_class("warning")}
          data-testid="scope-proof-pending"
        >
          <.icon name="hero-shield-exclamation" class="size-5" />
          <div>
            <p class="font-medium">Exact controller scope proof not recorded</p>
            <p class="text-sm">
              The execution must not be treated as safe to mutate until this proof is present.
            </p>
          </div>
        </div>

        <.diagnostics entries={@execution.diagnostics} subject="Execution" />

        <section class="space-y-3" aria-label="Exact execution targets">
          <div class="flex flex-wrap items-end justify-between gap-2">
            <div>
              <h4 class="font-semibold">Exact target tuples</h4>
              <p class="text-sm text-sr-muted">
                Controller + inventory + AWX host ID distinguish duplicate hostnames.
              </p>
            </div>
            <.ui_badge size="sm" variant="ghost">
              {length(@execution.targets)} target{plural(@execution.targets)}
            </.ui_badge>
          </div>

          <div
            :if={@execution.targets == []}
            role="status"
            class={ui_alert_class("warning")}
          >
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>No immutable target tuple is recorded for this execution.</span>
          </div>

          <div :if={@execution.targets != []} class="overflow-x-auto border border-sr-line">
            <table class={ui_table_class(size: "sm")} data-testid="secure-target-tuples">
              <thead>
                <tr>
                  <th>Controller</th>
                  <th>Inventory</th>
                  <th>AWX host</th>
                  <th>Membership</th>
                  <th>Canonical device</th>
                  <th>Generation</th>
                  <th>Host name</th>
                  <th>Address</th>
                  <th>Status</th>
                  <th>Snapshot</th>
                  <th>Diagnostics</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={target <- @execution.targets} id={"secure-target-#{target.id}"}>
                  <td><code class="text-xs break-all">{target.controller_id}</code></td>
                  <td><code class="text-xs">{target.inventory_id}</code></td>
                  <td><code class="text-xs">{target.awx_host_id}</code></td>
                  <td><code class="text-xs break-all">{target.membership_id}</code></td>
                  <td>
                    <.link
                      navigate={~p"/devices/#{target.canonical_device_uid}"}
                      class="text-sr-brand hover:underline font-mono text-xs break-all"
                    >
                      {target.canonical_device_uid}
                    </.link>
                  </td>
                  <td>{target.membership_generation}</td>
                  <td><code class="text-xs">{target.host_name}</code></td>
                  <td><code class="text-xs">{target.ansible_host || "—"}</code></td>
                  <td><span class={target_badge_classes(target.status)}>{target.status}</span></td>
                  <td><code class="text-xs break-all">{target.snapshot_digest}</code></td>
                  <td><.diagnostic_list entries={target.diagnostics} /></td>
                </tr>
              </tbody>
            </table>
          </div>

          <.target_hold
            :for={target <- @execution.targets}
            :if={target.active_hold}
            target={target}
          />
        </section>
      </div>
    </article>
    """
  end

  attr :target, :map, required: true

  defp target_hold(assigns) do
    ~H"""
    <div role="alert" class={ui_alert_class("error")} data-testid="secure-target-hold">
      <.icon name="hero-no-symbol" class="size-5" />
      <div class="min-w-0">
        <p class="font-medium">Target hold active · {target_label(@target)}</p>
        <p class="text-sm">
          Phase {@target.active_hold.trigger_phase}, generation {@target.active_hold.generation} · {@target.active_hold.reason}
        </p>
        <p class="mt-1 font-mono text-xs break-all">
          transaction {@target.active_hold.transaction_id} · evidence {@target.active_hold.evidence_digest}
        </p>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true
  attr :subject, :string, required: true

  defp state_alert(assigns) do
    assigns = assign(assigns, :alert, state_alert_content(assigns.state))

    ~H"""
    <div :if={@alert} role="alert" class={@alert.class} data-testid="automation-state-alert">
      <.icon name={@alert.icon} class="size-5" />
      <div>
        <p class="font-medium">{@subject}: {@alert.title}</p>
        <p class="text-sm">{@alert.message}</p>
      </div>
    </div>
    """
  end

  attr :entries, :list, required: true
  attr :subject, :string, required: true

  defp diagnostics(assigns) do
    ~H"""
    <section
      class="rounded-sr-surface border border-sr-line p-3"
      aria-label={"#{@subject} diagnostics"}
    >
      <h3 class="text-xs font-semibold uppercase tracking-wide text-sr-muted">
        Safe diagnostics
      </h3>
      <.diagnostic_list entries={@entries} />
      <p :if={@entries == []} class="mt-1 text-sm text-sr-muted">
        No allowlisted diagnostic fields are recorded. Sensitive and free-form values are withheld.
      </p>
    </section>
    """
  end

  attr :entries, :list, required: true

  defp diagnostic_list(assigns) do
    ~H"""
    <ul :if={@entries != []} class="mt-1 space-y-1 text-xs">
      <li :for={entry <- @entries}>
        <span class="text-sr-muted">{entry.label}:</span>
        <code class="break-all">{entry.value}</code>
      </li>
    </ul>
    <span :if={@entries == []} class="text-xs text-sr-muted">—</span>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  defp evidence_stat(assigns) do
    ~H"""
    <div class="stat min-w-0">
      <div class="sr-ui-stat-title">{@label}</div>
      <div class={["sr-ui-stat-value text-sm break-all", @mono && "font-mono"]}>
        {display(@value)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  defp evidence_card(assigns) do
    ~H"""
    <div class="rounded-sr-surface border border-sr-line p-3 min-w-0">
      <p class="text-xs uppercase tracking-wide text-sr-muted">{@label}</p>
      <p class={["mt-1 text-sm break-all", @mono && "font-mono"]}>{display(@value)}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :timezone, :string, required: true

  defp evidence_time_card(assigns) do
    ~H"""
    <div class="rounded-sr-surface border border-sr-line p-3 min-w-0">
      <p class="text-xs uppercase tracking-wide text-sr-muted">{@label}</p>
      <.user_time
        id={@id}
        value={@value}
        timezone={@timezone}
        style={:compact}
        class="mt-1 text-sm break-all"
      />
    </div>
    """
  end

  @doc false
  def state_badge_classes(state) do
    ["badge", "badge-sm", state_badge_class(state)]
  end

  @doc false
  def target_badge_classes(status) do
    ["badge", "badge-sm", target_badge_class(status)]
  end

  defp state_alert_content(:dispatch_partial) do
    %{
      class: ui_alert_class("warning"),
      icon: "hero-exclamation-triangle",
      title: "partial dispatch",
      message: "One or more inventory-bound child executions did not dispatch. Review each child before retrying."
    }
  end

  defp state_alert_content(:dispatch_ambiguous) do
    %{
      class: ui_alert_class("error"),
      icon: "hero-question-mark-circle",
      title: "dispatch outcome is ambiguous",
      message:
        "ServiceRadar cannot prove whether AWX accepted this dispatch. Do not retry until controller-local job evidence is reconciled."
    }
  end

  defp state_alert_content(:cancel_failed) do
    %{
      class: ui_alert_class("error"),
      icon: "hero-x-circle",
      title: "cancellation failed",
      message:
        "The cancellation request could not be proven across all affected controller jobs. Treat the operation as potentially active."
    }
  end

  defp state_alert_content(:canceled) do
    %{
      class: ui_alert_class("info"),
      icon: "hero-no-symbol",
      title: "canceled",
      message:
        "The persisted lifecycle records this operation as canceled. Per-target outcomes remain the authoritative scope evidence."
    }
  end

  defp state_alert_content(:failed) do
    %{
      class: ui_alert_class("error"),
      icon: "hero-x-circle",
      title: "failed",
      message: "The operation failed. Review safe diagnostics, scope proof, and exact target status before any retry."
    }
  end

  defp state_alert_content(_state), do: nil

  defp state_badge_class(:succeeded), do: "badge-success"
  defp state_badge_class(:running), do: "badge-info"
  defp state_badge_class(:scope_verified), do: "badge-info"
  defp state_badge_class(:launching), do: "badge-info"
  defp state_badge_class(:dispatching), do: "badge-info"
  defp state_badge_class(:dispatch_partial), do: "badge-warning"
  defp state_badge_class(:dispatch_ambiguous), do: "badge-error"
  defp state_badge_class(:cancel_failed), do: "badge-error"
  defp state_badge_class(:failed), do: "badge-error"
  defp state_badge_class(:canceled), do: "badge-neutral"
  defp state_badge_class(_state), do: "badge-ghost"

  defp target_badge_class(:ok), do: "badge-success"
  defp target_badge_class(:running), do: "badge-info"
  defp target_badge_class(:failed), do: "badge-error"
  defp target_badge_class(:unreachable), do: "badge-error"
  defp target_badge_class(:scope_mismatch), do: "badge-error"
  defp target_badge_class(:canceled), do: "badge-neutral"
  defp target_badge_class(:skipped), do: "badge-neutral"
  defp target_badge_class(_status), do: "badge-ghost"

  defp principal(operation) do
    "#{operation.initiator_principal_type}:#{operation.initiator_principal_id}"
  end

  defp operation_mode(%{check_mode: true}), do: "Check mode"
  defp operation_mode(%{mutating: true}), do: "Mutating run"
  defp operation_mode(_operation), do: "Read-only run"

  defp controller_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp controller_name(_controller), do: "Controller"

  defp target_label(target), do: "#{target.host_name} (AWX host #{target.awx_host_id})"

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"
  defp yes_no(_value), do: "—"

  defp display(nil), do: "—"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  defp short_id(value) when is_binary(value) and byte_size(value) > 8, do: String.slice(value, 0, 8) <> "…"

  defp short_id(value), do: display(value)

  defp plural(collection), do: if(length(collection) == 1, do: "", else: "s")
end
