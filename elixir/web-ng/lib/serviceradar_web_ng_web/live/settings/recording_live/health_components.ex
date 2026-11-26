defmodule ServiceRadarWebNGWeb.Settings.RecordingLive.HealthComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  # --- C.17 Per-Member NVRStorageSettings on Recorders tab -------------------

  attr :can_manage?, :boolean, required: true
  attr :storage_rows, :list, required: true
  attr :storage_settings_form, :map, required: true
  attr :storage_settings_errors, :map, default: %{}
  attr :timezone, :string, default: "Etc/UTC"

  def storage_settings_section(assigns) do
    ~H"""
    <div id="recording-member-budgets-section" class="space-y-4">
      <div class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-sm font-semibold text-sr-ink">
            Per-Member Local Byte Budget &amp; Reserve (<code class="font-mono">NVRStorageSettings</code>)
          </h3>
          <.ui_badge size="xs" variant="ghost">Desired vs applied</.ui_badge>
        </div>

        <p id="recorders-install-defaults-callout" class="text-xs text-sr-muted">
          Chart install defaults derive from the PVC size:
          <strong class="text-sr-ink">85% of PVC minus max(64 MiB, 1%)</strong>
          (<code class="font-mono">nvr.maxSpoolBytes</code>
          ceiling/default, e.g. <code class="font-mono">84.0 GiB</code>
          budget and <code class="font-mono">1 GiB</code>
          reserve on a <code class="font-mono">100 GiB</code>
          PVC). Desired settings saved below
          persist in CNPG (<code class="font-mono">platform.camera_nvr_storage_settings</code>) with
          Core's pinned-bytes floor check (<code class="font-mono">pinned_bytes + 2 * 16 MiB</code>);
          live member push and disk/status measurements (<code class="font-mono">PUT /v1/storage/settings</code>, <code class="font-mono">GET /v1/status</code>, and <code class="font-mono">NVRStorageSettingsSyncJob</code>) activate with <code class="font-mono">C.14</code>–<code class="font-mono">C.16</code>.
        </p>

        <p
          :if={@storage_rows == []}
          id="recording-storage-settings-empty"
          class="text-xs text-sr-muted"
        >
          Per-member local byte budget (<code class="font-mono">budget_bytes</code>), free-space
          reserve (<code class="font-mono">reserve_bytes</code>), install ceiling
          (<code class="font-mono">nvr.maxSpoolBytes</code>) and floor
          (<code class="font-mono">nvr.reserveBytes</code>), volume capacity, and effective local
          window are reported as <strong>unknown</strong>
          until the NVR member <code class="font-mono">GET /v1/status</code>
          endpoint answers or a storage UUID is
          configured below.
        </p>

        <div :if={@storage_rows != []} class="overflow-x-auto pt-1">
          <table id="recording-storage-settings-table" class="w-full text-left text-xs">
            <thead class="border-b border-sr-line text-sr-muted">
              <tr>
                <th class="py-2 pr-3 font-medium">Storage UUID</th>
                <th class="py-2 pr-3 font-medium">Desired Budget</th>
                <th class="py-2 pr-3 font-medium">Desired Reserve</th>
                <th class="py-2 pr-3 font-medium">Revision &amp; Sync State</th>
                <th class="py-2 pr-3 font-medium">Pinned Floor &amp; Window</th>
                <th :if={@can_manage?} class="py-2 font-medium">Action</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-sr-line">
              <tr
                :for={row <- @storage_rows}
                id={"storage-settings-row-#{row.storage_id}"}
                class="align-top"
              >
                <td class="py-2.5 pr-3 font-mono text-sr-ink">
                  <div>{row.storage_id}</div>
                  <div :if={row.member_name} class="text-[11px] text-sr-muted">
                    member: {row.member_name}
                  </div>
                </td>
                <td class="py-2.5 pr-3 text-sr-ink">
                  {format_desired_budget(row.desired_settings)}
                </td>
                <td class="py-2.5 pr-3 text-sr-ink">
                  {format_desired_reserve(row.desired_settings)}
                </td>
                <td class="py-2.5 pr-3 space-y-1">
                  <div class="flex flex-wrap items-center gap-1.5">
                    <.ui_badge
                      id={"storage-settings-rev-#{row.storage_id}"}
                      size="xs"
                      variant="outline"
                    >
                      {format_storage_revision_label(row)}
                    </.ui_badge>
                    <.ui_badge
                      id={"storage-settings-sync-#{row.storage_id}"}
                      size="xs"
                      variant={sync_badge_variant(row)}
                    >
                      {format_sync_badge_label(row)}
                    </.ui_badge>
                  </div>
                  <div class="text-[11px] text-sr-muted">
                    {format_applied_revision_note(row)}
                    <span :if={fetch_val(row.desired_settings, :applied_at)}>
                      ·
                      <.user_time
                        id={"storage-settings-applied-at-#{row.storage_id}"}
                        value={fetch_val(row.desired_settings, :applied_at)}
                        timezone={@timezone}
                        style={:compact}
                      />
                    </span>
                  </div>
                </td>
                <td class="py-2.5 pr-3 text-[11px] text-sr-muted space-y-0.5">
                  <div>
                    Pinned:
                    <span class="font-mono text-sr-ink">{format_bytes(row.pinned_bytes)}</span>
                    · Floor:
                    <span class="font-mono text-sr-ink">
                      {format_bytes(row.min_custom_budget_bytes)}
                    </span>
                  </div>
                  <div>{format_local_window_summary(row.window_projection)}</div>
                </td>
                <td :if={@can_manage?} class="py-2.5">
                  <.ui_button
                    id={"select-storage-settings-#{row.storage_id}"}
                    type="button"
                    phx-click="select_storage_settings"
                    phx-value-id={row.storage_id}
                    variant="outline"
                    size="xs"
                  >
                    Configure
                  </.ui_button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <form
        id="recording-storage-settings-form"
        phx-change="preview_storage_settings"
        phx-submit="save_storage_settings"
        class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-4"
      >
        <div>
          <h4 class="text-xs font-semibold text-sr-ink">
            Configure Desired Per-Member Storage Budget &amp; Reserve
          </h4>
          <p class="mt-0.5 text-[11px] text-sr-muted">
            Keyed by NVR storage UUID (<code class="font-mono">storage_id</code>). Custom budgets
            below <code class="font-mono">pinned_bytes + 33,554,432</code> (two 16 MiB block
            reservations) or custom reserves below <code class="font-mono">67,108,864</code> (64 MiB)
            are refused at save time.
          </p>
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <div class="md:col-span-2">
            <label
              for="storage-settings-storage-id-input"
              class="block text-xs font-medium text-sr-ink"
            >
              NVR storage UUID (<code class="font-mono">storage_id</code>)
            </label>
            <input
              id="storage-settings-storage-id-input"
              type="text"
              name="storage_settings[storage_id]"
              value={@storage_settings_form["storage_id"]}
              list="known-nvr-storage-ids"
              disabled={!@can_manage?}
              placeholder="00000000-0000-4000-8000-000000000000"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            />
            <datalist id="known-nvr-storage-ids">
              <option :for={row <- @storage_rows} value={row.storage_id} />
            </datalist>
            <p
              :if={@storage_settings_errors[:storage_id]}
              id="storage-settings-error-storage-id"
              class="mt-1 text-xs text-rose-500"
            >
              {@storage_settings_errors[:storage_id]}
            </p>
          </div>

          <div>
            <label
              for="storage-settings-budget-mode-select"
              class="block text-xs font-medium text-sr-ink"
            >
              Local byte budget mode
            </label>
            <select
              id="storage-settings-budget-mode-select"
              name="storage_settings[budget_mode]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                value="install_default"
                selected={@storage_settings_form["budget_mode"] == "install_default"}
              >
                install_default (85% of PVC minus reserve)
              </option>
              <option
                value="custom"
                selected={@storage_settings_form["budget_mode"] == "custom"}
              >
                custom (explicit byte budget)
              </option>
            </select>
          </div>

          <div>
            <label
              for="storage-settings-budget-bytes-input"
              class="block text-xs font-medium text-sr-ink"
            >
              Custom budget bytes (&gt;= <code class="font-mono">pinned_bytes + 32 MiB</code>)
            </label>
            <input
              id="storage-settings-budget-bytes-input"
              type="number"
              min="33554432"
              name="storage_settings[budget_bytes]"
              value={@storage_settings_form["budget_bytes"]}
              disabled={!@can_manage? or @storage_settings_form["budget_mode"] != "custom"}
              placeholder="10737418240"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            />
            <p
              :if={@storage_settings_errors[:budget_bytes]}
              id="storage-settings-error-budget-bytes"
              class="mt-1 text-xs text-rose-500"
            >
              {@storage_settings_errors[:budget_bytes]}
            </p>
          </div>

          <div>
            <label
              for="storage-settings-reserve-mode-select"
              class="block text-xs font-medium text-sr-ink"
            >
              Free-space reserve mode
            </label>
            <select
              id="storage-settings-reserve-mode-select"
              name="storage_settings[reserve_mode]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                value="install_default"
                selected={@storage_settings_form["reserve_mode"] == "install_default"}
              >
                install_default (max(64 MiB, 1% of PVC))
              </option>
              <option
                value="custom"
                selected={@storage_settings_form["reserve_mode"] == "custom"}
              >
                custom (explicit reserve bytes)
              </option>
            </select>
          </div>

          <div>
            <label
              for="storage-settings-reserve-bytes-input"
              class="block text-xs font-medium text-sr-ink"
            >
              Custom reserve bytes (&gt;= <code class="font-mono">67,108,864</code>)
            </label>
            <input
              id="storage-settings-reserve-bytes-input"
              type="number"
              min="67108864"
              name="storage_settings[reserve_bytes]"
              value={@storage_settings_form["reserve_bytes"]}
              disabled={!@can_manage? or @storage_settings_form["reserve_mode"] != "custom"}
              placeholder="67108864"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            />
            <p
              :if={@storage_settings_errors[:reserve_bytes]}
              id="storage-settings-error-reserve-bytes"
              class="mt-1 text-xs text-rose-500"
            >
              {@storage_settings_errors[:reserve_bytes]}
            </p>
          </div>
        </div>

        <p
          :if={@storage_settings_errors[:base]}
          id="storage-settings-error-base"
          class="text-xs text-rose-500"
        >
          {@storage_settings_errors[:base]}
        </p>

        <div :if={@can_manage?} class="flex justify-end">
          <.ui_button id="save-storage-settings-btn" type="submit" variant="primary" size="sm">
            Save storage settings
          </.ui_button>
        </div>
      </form>
    </div>
    """
  end

  # --- E.3 / R.10 Health Tab Cards -------------------------------------------

  attr :backlog, :map, required: true
  attr :storage_mode, :atom, default: :local_only

  def backlog_card(assigns) do
    terminal_count = Map.get(assigns.backlog, :failed_terminal_count, 0)
    assigns = assign(assigns, :terminal_count, terminal_count)

    ~H"""
    <section
      id="recording-health-backlog-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Archive Upload Backlog</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Live CNPG <code class="font-mono">RecordingCatalogEntry</code>
            archive states
            (<code class="font-mono">awaiting_binding</code>, <code class="font-mono">pending</code>, <code class="font-mono">failed_retryable</code>, and <code class="font-mono">failed_terminal</code>). Unarchived local copies stay pinned in
            <code class="font-mono">P1</code>
            and are never evicted.
          </p>
        </div>
        <.ui_badge
          id="health-storage-mode-badge"
          size="xs"
          variant={if(@storage_mode == :local_and_archive, do: "success", else: "ghost")}
        >
          {if @storage_mode == :local_and_archive,
            do: "Local + archive",
            else: "Local only: no object storage configured"}
        </.ui_badge>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div
          id="health-backlog-unarchived"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Unarchived blocks &amp; bytes</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@backlog.unarchived_count} blocks ({format_bytes(@backlog.unarchived_bytes)})
          </div>
          <div class="text-[11px] text-sr-muted">
            Pending: {@backlog.pending_count}
          </div>
        </div>

        <div
          id="health-backlog-oldest-age"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Oldest unarchived age</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {format_age_seconds(@backlog.oldest_unarchived_age_seconds)}
          </div>
          <div class="text-[11px] text-sr-muted">
            Alarm threshold: 1 hour
          </div>
        </div>

        <div
          id="health-backlog-awaiting-binding"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Awaiting binding</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@backlog.awaiting_binding_count}
          </div>
          <div class="text-[11px] text-sr-muted">
            <code class="font-mono">awaiting_binding</code>
          </div>
        </div>

        <div
          id="health-backlog-failed-retryable"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Retryable failures</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@backlog.failed_retryable_count}
          </div>
          <div class="text-[11px] text-sr-muted">
            <code class="font-mono">failed_retryable</code>
          </div>
        </div>

        <div
          id="health-backlog-failed-terminal"
          class={[
            "rounded-lg border p-3 space-y-1",
            if(@terminal_count > 0,
              do: "border-rose-500/50 bg-rose-500/10",
              else: "border-sr-line bg-sr-subtle/30"
            )
          ]}
        >
          <div class="flex items-center justify-between gap-1">
            <span class="text-xs text-sr-muted">Terminal failures</span>
            <.ui_badge
              :if={@terminal_count > 0}
              id="health-failed-terminal-badge"
              size="xs"
              variant="error"
            >
              Action required
            </.ui_badge>
          </div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@terminal_count}
          </div>
          <div class="text-[11px] text-sr-muted">
            <code class="font-mono">failed_terminal</code>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :storage_members, :list, required: true
  attr :unassigned_continuous_cameras, :integer, default: 0

  def storage_capacity_card(assigns) do
    ~H"""
    <section
      id="recording-health-storage-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Per-Storage Local Capacity &amp; Effective Window
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            CNPG-derived present and pinned bytes, effective local window projection with binding
            bound, pinned-growth <code class="font-mono">time_to_full</code>, assigned continuous
            cameras, and live NVR <code class="font-mono">/v1/status</code> disk capacity and
            inventory ledger audit state per NVR storage UUID.
          </p>
        </div>
        <.ui_badge
          :if={@unassigned_continuous_cameras > 0}
          id="health-unmapped-continuous-badge"
          size="xs"
          variant="ghost"
        >
          {@unassigned_continuous_cameras} continuous policy(ies) awaiting member storage mapping
        </.ui_badge>
      </div>

      <p
        :if={@storage_members == []}
        id="health-storage-empty"
        class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 text-xs text-sr-muted"
      >
        No cataloged storage UUIDs recorded in CNPG yet. Live NVR disk capacity and inventory ledger
        state are <strong>unknown until NVR /v1/status reports</strong>.
      </p>

      <div :if={@storage_members != []} class="grid gap-3 md:grid-cols-2">
        <div
          :for={member <- @storage_members}
          id={"health-storage-member-#{member.storage_id}"}
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-4 space-y-2"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="font-mono text-xs font-semibold text-sr-ink">
              {member.storage_id}
              <span :if={member.member_name} class="font-sans font-normal text-sr-muted">
                ({member.member_name})
              </span>
            </div>
            <.ui_badge size="xs" variant="ghost">
              {format_local_bound_badge(member.window_projection.binding_bound)}
            </.ui_badge>
          </div>

          <p class="text-xs font-medium text-sr-ink">
            {format_local_window_summary(member.window_projection)}
          </p>

          <div class="grid gap-2 sm:grid-cols-2 text-[11px] text-sr-muted">
            <div>
              Local present:
              <span class="font-mono text-sr-ink">{format_bytes(member.local_present_bytes)}</span>
              ({member.local_present_blocks} blocks)
            </div>
            <div>
              Pinned bytes (<code class="font-mono">C1a</code>):
              <span class="font-mono text-sr-ink">{format_bytes(member.pinned_bytes)}</span>
            </div>
            <div>
              Time-to-full:
              <strong class="text-sr-ink">
                {format_time_to_full(member.time_to_full_seconds)}
              </strong>
            </div>
            <div>
              Assigned continuous cameras:
              <span class="font-mono text-sr-ink">{member.assigned_continuous_cameras}</span>
            </div>
          </div>

          <div
            :if={live_capacity_present?(member)}
            id={"health-storage-member-live-#{member.storage_id}"}
            class="rounded-md border border-sr-line/80 bg-sr-surface/70 p-2.5 space-y-2 text-[11px] text-sr-muted"
          >
            <div
              :if={live_spool_bar_present?(member)}
              id={"health-storage-member-spool-#{member.storage_id}"}
              class="space-y-1"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <span>
                  Spool used:
                  <span class="font-mono text-sr-ink">
                    {format_bytes(live_field(member, :used_bytes))} / {format_bytes(
                      live_field(member, :max_spool_bytes)
                    )}
                  </span>
                </span>
                <span class="font-mono font-semibold text-sr-ink">
                  {format_num(live_used_percent(member))}%
                </span>
              </div>
              <div
                class="h-1.5 w-full overflow-hidden rounded-full bg-sr-line/60"
                role="progressbar"
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={trunc(live_used_percent(member))}
              >
                <div
                  class={[
                    "h-full rounded-full transition-all",
                    spool_bar_color(live_used_percent(member))
                  ]}
                  style={"width: #{live_used_percent(member)}%"}
                />
              </div>
            </div>

            <div
              id={"health-storage-member-disk-metrics-#{member.storage_id}"}
              class="flex flex-wrap items-center gap-x-3 gap-y-1"
            >
              <span :if={is_integer(live_field(member, :available_bytes))}>
                Free:
                <span class="font-mono text-sr-ink">
                  {format_bytes(live_field(member, :available_bytes))}
                </span>
                <span :if={is_integer(live_field(member, :reserve_bytes))}>
                  (reserve {format_bytes(live_field(member, :reserve_bytes))})
                </span>
              </span>
              <span :if={is_integer(live_field(member, :blocks))}>
                Ledger blocks:
                <span class="font-mono text-sr-ink">
                  {live_field(member, :blocks)}<span :if={is_integer(live_field(member, :max_blocks))}> / {live_field(
                    member,
                    :max_blocks
                  )}</span>
                </span>
              </span>
              <span :if={
                is_integer(live_field(member, :reservations)) and
                  live_field(member, :reservations) > 0
              }>
                Active writers:
                <span class="font-mono text-sr-ink">{live_field(member, :reservations)}</span>
              </span>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2 pt-1 text-[11px] text-sr-muted">
            <.ui_badge
              id={"health-storage-member-ledger-#{member.storage_id}"}
              size="xs"
              variant={live_ledger_badge_variant(member)}
            >
              Disk &amp; ledger: {format_live_ledger_status(member)}
            </.ui_badge>
            <span :if={is_map(Map.get(member, :reservations))}>
              · Reservations:
              <span class="font-mono text-sr-ink">
                {Map.get(member.reservations, :unresolved_count, 0)} unresolved / {Map.get(
                  member.reservations,
                  :adopted_count,
                  0
                )} adopted
              </span>
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :health_summary, :map, default: %{}
  attr :backlog, :map, required: true
  attr :dispositions, :map, required: true
  attr :can_operate?, :boolean, default: false
  attr :can_hold?, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def reconciliation_and_dispositions_card(assigns) do
    reason_pairs =
      assigns.dispositions
      |> Map.get(:by_reason_24h, %{})
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)

    reservations = extract_reservations_breakdown(assigns.health_summary)
    quarantined_rows = resolve_quarantined_rows(assigns.health_summary, assigns.backlog)
    missing_rows = resolve_missing_archive_rows(assigns.health_summary, assigns.backlog)

    missing_count =
      max(
        Map.get(assigns.health_summary, :missing_archive_count, 0),
        max(Map.get(assigns.backlog, :missing_count, 0), length(missing_rows))
      )

    unattributable_count =
      max(
        Map.get(assigns.health_summary, :unattributable_count, 0),
        Map.get(assigns.backlog, :unattributable_count, 0)
      )

    assigns =
      assigns
      |> assign(:reason_pairs, reason_pairs)
      |> assign(:reservations, reservations)
      |> assign(:quarantined_rows, quarantined_rows)
      |> assign(:missing_rows, missing_rows)
      |> assign(:missing_count, missing_count)
      |> assign(:unattributable_count, unattributable_count)

    ~H"""
    <section
      id="recording-health-reconciliation-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-5"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Reconciliation, Quarantine &amp; Retention Dispositions
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Core reservation resolution state, unattributable and quarantined catalog entries with
            audited operator actions, 24-hour append-only
            <code class="font-mono">RecordingDisposition</code>
            counts and failures, and missing archive copy acceptance.
          </p>
        </div>
        <.ui_badge
          id="health-reconciler-status"
          size="xs"
          variant={if(@backlog.reconciler_status == :active, do: "success", else: "ghost")}
        >
          <%= if @backlog.reconciler_last_pass_at do %>
            Last pass:
            <.user_time
              id="health-reconciler-last-pass"
              value={@backlog.reconciler_last_pass_at}
              timezone={@timezone}
              style={:compact}
            />
          <% else %>
            NVRReconcileJob: awaiting reconciler
          <% end %>
        </.ui_badge>
      </div>

      <div id="health-reservations-breakdown" class="space-y-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-xs font-semibold text-sr-ink">
            Core Reservation Resolution Breakdown (<code class="font-mono">RecordingBlock.reconciliation_state</code>)
          </h3>
          <.ui_badge id="health-reservations-total-badge" size="xs" variant="ghost">
            Total reservations: {@reservations.total_count}
          </.ui_badge>
        </div>

        <div class="grid gap-2.5 sm:grid-cols-2 lg:grid-cols-4">
          <div
            id="health-reservations-unresolved"
            class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-0.5"
          >
            <div class="text-xs text-sr-muted">Unresolved</div>
            <div class="text-sm font-semibold font-mono text-sr-ink">
              {@reservations.unresolved_count}
            </div>
            <div class="text-[11px] font-mono text-sr-muted">unresolved</div>
          </div>

          <div
            id="health-reservations-adopted"
            class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-0.5"
          >
            <div class="text-xs text-sr-muted">Adopted (sealed)</div>
            <div class="text-sm font-semibold font-mono text-sr-ink">
              {@reservations.adopted_count}
            </div>
            <div class="text-[11px] font-mono text-sr-muted">adopted</div>
          </div>

          <div
            id="health-reservations-block-absent"
            class={[
              "rounded-lg border p-3 space-y-0.5",
              if(@reservations.block_absent_count > 0,
                do: "border-amber-500/40 bg-amber-500/5",
                else: "border-sr-line bg-sr-subtle/30"
              )
            ]}
          >
            <div class="text-xs text-sr-muted">Resolved: block absent</div>
            <div class="text-sm font-semibold font-mono text-sr-ink">
              {@reservations.block_absent_count}
            </div>
            <div class="text-[11px] font-mono text-sr-muted">block_absent</div>
          </div>

          <div
            id="health-reservations-unrecoverable-journal"
            class={[
              "rounded-lg border p-3 space-y-0.5",
              if(@reservations.unrecoverable_journal_count > 0,
                do: "border-rose-500/40 bg-rose-500/10",
                else: "border-sr-line bg-sr-subtle/30"
              )
            ]}
          >
            <div class="text-xs text-sr-muted">Resolved: unrecoverable journal</div>
            <div class="text-sm font-semibold font-mono text-sr-ink">
              {@reservations.unrecoverable_journal_count}
            </div>
            <div class="text-[11px] font-mono text-sr-muted">unrecoverable_journal</div>
          </div>
        </div>
      </div>

      <div class="grid gap-3 sm:grid-cols-3">
        <div
          id="health-quarantined-summary"
          class={[
            "rounded-lg border p-3 space-y-1",
            if(@backlog.quarantined_count > 0,
              do: "border-amber-500/40 bg-amber-500/5",
              else: "border-sr-line bg-sr-subtle/30"
            )
          ]}
        >
          <div class="text-xs text-sr-muted">Quarantined / unattributable</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@backlog.quarantined_count} entries ({format_bytes(@backlog.quarantined_bytes)})
          </div>
          <div class="text-[11px] text-sr-muted">
            Unattributable: {@unattributable_count} · Pinned as row (q), excluded from playback &amp; eviction
          </div>
        </div>

        <div
          id="health-dispositions-24h-summary"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">24h RecordingDispositions</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@dispositions.recent_dispositions_24h} steps ({@dispositions.verified_absent_24h} verified absent)
          </div>
          <div class="text-[11px] text-sr-muted">
            Failures (24h):
            <strong class={
              if(@dispositions.failed_dispositions_24h > 0, do: "text-rose-500", else: "text-sr-ink")
            }>
              {@dispositions.failed_dispositions_24h}
            </strong>
            <span :if={@reason_pairs != []}>
              · {format_disposition_reasons(@reason_pairs)}
            </span>
          </div>
        </div>

        <div
          id="health-held-missing-summary"
          class={[
            "rounded-lg border p-3 space-y-1",
            if(@dispositions.held_archive_missing_count > 0 or @missing_count > 0,
              do: "border-rose-500/40 bg-rose-500/10",
              else: "border-sr-line bg-sr-subtle/30"
            )
          ]}
        >
          <div class="text-xs text-sr-muted">Holds &amp; missing archive copies</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            Held missing: {@dispositions.held_archive_missing_count} · Archive missing: {@missing_count}
          </div>
          <div class="text-[11px] text-sr-muted">
            Active holds: {@dispositions.active_hold_count}
          </div>
        </div>
      </div>

      <div :if={@quarantined_rows != []} id="health-quarantined-list" class="space-y-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-xs font-semibold text-sr-ink">
            Unattributable / Quarantined Blocks
          </h3>
          <span
            id="health-quarantine-rbac-note"
            class="text-[11px] text-sr-muted"
          >
            {if @can_operate?,
              do:
                "Audited operator delete intent (with confirmation) and export / preserve intent enabled",
              else: "Operator disposition requires settings.recording.operate"}
          </span>
        </div>

        <div class="overflow-x-auto">
          <table id="health-quarantined-table" class="w-full text-left text-xs">
            <thead class="border-b border-sr-line text-sr-muted">
              <tr>
                <th class="py-1.5 pr-3 font-medium">Storage ID</th>
                <th class="py-1.5 pr-3 font-medium">Block Key</th>
                <th class="py-1.5 pr-3 font-medium">Reason &amp; Evidence</th>
                <th class="py-1.5 pr-3 font-medium">Recorded At</th>
                <th class="py-1.5 pr-3 font-medium">Disposition State</th>
                <th :if={@can_operate?} class="py-1.5 font-medium">Operator Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-sr-line">
              <tr
                :for={q <- @quarantined_rows}
                id={"health-quarantined-entry-#{q.id}"}
                class="align-top"
              >
                <td class="py-2.5 pr-3 font-mono text-[11px] text-sr-muted">
                  {q.storage_id || "—"}
                </td>
                <td class="py-2.5 pr-3 font-mono text-sr-ink">
                  <div>{q.block_key}</div>
                  <div class="text-[11px] font-sans text-sr-muted">
                    {format_bytes(q.quarantined_bytes)}
                  </div>
                </td>
                <td class="py-2.5 pr-3 space-y-1">
                  <.ui_badge size="xs" variant="error">
                    {to_string(q.quarantine_reason || :quarantined)}
                  </.ui_badge>
                  <div class="text-[11px] text-sr-muted">
                    {format_quarantine_row_evidence(q)}
                  </div>
                </td>
                <td class="py-2.5 pr-3 text-[11px] text-sr-muted">
                  <%= if q.recorded_at do %>
                    <.user_time
                      id={"health-quarantined-at-#{q.id}"}
                      value={q.recorded_at}
                      timezone={@timezone}
                      style={:compact}
                    />
                  <% else %>
                    —
                  <% end %>
                </td>
                <td class="py-2.5 pr-3 space-y-1">
                  <div class="flex flex-wrap items-center gap-1.5">
                    <.ui_badge
                      id={"health-quarantined-disposition-#{q.id}"}
                      size="xs"
                      variant={quarantine_disposition_badge_variant(q)}
                    >
                      {format_quarantine_disposition_label(q)}
                    </.ui_badge>
                    <span class="font-mono text-[11px] text-sr-muted">
                      archive: {to_string(q.archive_state)}
                    </span>
                  </div>
                  <div
                    :if={quarantine_decision_note(q)}
                    class="text-[11px] text-sr-muted"
                  >
                    {quarantine_decision_note(q)}
                  </div>
                </td>
                <td :if={@can_operate?} class="py-2.5">
                  <%= if quarantine_row_actionable?(q) do %>
                    <div class="space-y-2">
                      <div class="flex flex-wrap items-center gap-1.5">
                        <.ui_button
                          :if={quarantine_exportable?(q)}
                          id={"request-quarantine-export-#{q.id}"}
                          type="button"
                          phx-click="request_quarantine_export"
                          phx-value-id={q.id}
                          variant="outline"
                          size="xs"
                        >
                          Export / Preserve Intent
                        </.ui_button>
                      </div>

                      <details
                        id={"quarantine-delete-disclosure-#{q.id}"}
                        class="rounded-lg border border-rose-500/30 bg-rose-500/5 p-2 text-xs"
                      >
                        <summary class="cursor-pointer font-medium text-rose-500 select-none">
                          Audited Delete Intent…
                        </summary>
                        <form
                          id={"quarantine-delete-form-#{q.id}"}
                          phx-submit="request_quarantine_delete"
                          class="mt-2 space-y-2"
                        >
                          <input type="hidden" name="delete[id]" value={q.id} />
                          <input type="hidden" name="delete[confirm]" value="false" />
                          <label class="flex items-start gap-2 text-[11px] text-sr-ink">
                            <input
                              id={"confirm-quarantine-delete-checkbox-#{q.id}"}
                              type="checkbox"
                              name="delete[confirm]"
                              value="true"
                              class="mt-0.5 rounded border-sr-line"
                            />
                            <span>
                              Confirm permanent NVR reclaim and audited
                              <code class="font-mono">operator_quarantine</code>
                              disposition
                            </span>
                          </label>
                          <input
                            id={"quarantine-delete-note-#{q.id}"}
                            type="text"
                            name="delete[note]"
                            placeholder="Optional operator audit note"
                            class="w-full rounded border border-sr-line bg-sr-canvas px-2 py-1 text-[11px] text-sr-ink"
                          />
                          <div class="flex justify-end">
                            <.ui_button
                              id={"confirm-quarantine-delete-btn-#{q.id}"}
                              type="submit"
                              variant="danger"
                              size="xs"
                            >
                              Confirm Delete Intent
                            </.ui_button>
                          </div>
                        </form>
                      </details>
                    </div>
                  <% else %>
                    <span class="text-[11px] text-sr-muted">
                      {format_quarantine_action_locked(q)}
                    </span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div
        :if={@missing_count > 0 or @missing_rows != []}
        id="health-missing-archive-list"
        class="rounded-lg border border-rose-500/40 bg-rose-500/5 p-4 space-y-3"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="text-xs font-semibold text-sr-ink">
            Missing Archive Copies (<code class="font-mono">archive_state = missing</code>)
          </div>
          <span
            id="health-missing-archive-rbac-note"
            class="text-[11px] text-sr-muted"
          >
            {if @can_operate?,
              do:
                "Audited re-archive or loss acceptance (held entries require devices.cameras.recordings.hold)",
              else: "Operator resolution requires settings.recording.operate"}
          </span>
        </div>

        <div :if={@missing_rows != []} class="overflow-x-auto">
          <table id="health-missing-archive-table" class="w-full text-left text-xs">
            <thead class="border-b border-rose-500/20 text-sr-muted">
              <tr>
                <th class="py-1.5 pr-3 font-medium">Block Key &amp; Storage</th>
                <th class="py-1.5 pr-3 font-medium">Local Copy</th>
                <th class="py-1.5 pr-3 font-medium">Hold Status</th>
                <th :if={@can_operate?} class="py-1.5 font-medium">Operator Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-rose-500/20">
              <tr
                :for={m <- @missing_rows}
                id={"health-missing-entry-#{m.id}"}
                class="align-top"
              >
                <td class="py-2 pr-3">
                  <div class="font-mono text-sr-ink">{m.block_key}</div>
                  <div class="font-mono text-[11px] text-sr-muted">
                    {Map.get(m, :storage_id) || "—"} · {format_bytes(m.media_bytes)}
                  </div>
                </td>
                <td class="py-2 pr-3">
                  <code class="font-mono text-sr-ink">{to_string(m.local_state)}</code>
                  <div
                    :if={Map.get(m, :archive_last_error_class)}
                    class="font-mono text-[11px] text-sr-muted"
                  >
                    error: {Map.get(m, :archive_last_error_class)}
                  </div>
                </td>
                <td class="py-2 pr-3 space-y-1">
                  <%= if Map.get(m, :held?) do %>
                    <.ui_badge size="xs" variant="error">
                      HELD ({max(1, Map.get(m, :hold_count, 1))})
                    </.ui_badge>
                    <div class="text-[11px] text-sr-muted">
                      Loss acceptance requires
                      <code class="font-mono">devices.cameras.recordings.hold</code>
                    </div>
                  <% else %>
                    <.ui_badge size="xs" variant="ghost">Unheld</.ui_badge>
                  <% end %>
                </td>
                <td :if={@can_operate?} class="py-2">
                  <div class="flex flex-wrap items-start gap-2">
                    <.ui_button
                      :if={Map.get(m, :rearchive_eligible?) == true}
                      id={"rearchive-missing-entry-#{m.id}"}
                      type="button"
                      phx-click="rearchive_missing_archive"
                      phx-value-id={m.id}
                      variant="outline"
                      size="xs"
                    >
                      Re-archive
                    </.ui_button>

                    <%= if Map.get(m, :held?) == true and not @can_hold? do %>
                      <span
                        id={"accept-missing-loss-hold-required-#{m.id}"}
                        class="inline-flex items-center rounded border border-rose-500/40 px-2 py-1 text-[11px] text-rose-500"
                      >
                        Accept Archive Loss requires
                        <code class="ml-1 font-mono">devices.cameras.recordings.hold</code>
                      </span>
                    <% else %>
                      <form
                        id={"accept-missing-loss-form-#{m.id}"}
                        phx-submit="accept_missing_archive_loss"
                        class="flex flex-wrap items-center gap-1.5"
                      >
                        <input type="hidden" name="loss[id]" value={m.id} />
                        <input
                          id={"accept-missing-loss-note-#{m.id}"}
                          type="text"
                          name="loss[note]"
                          placeholder="Audit note (optional)"
                          class="rounded border border-sr-line bg-sr-canvas px-2 py-1 text-[11px] text-sr-ink"
                        />
                        <.ui_button
                          id={"accept-missing-loss-btn-#{m.id}"}
                          type="submit"
                          variant="warning"
                          size="xs"
                        >
                          Accept Archive Loss
                        </.ui_button>
                      </form>
                    <% end %>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr :gaps_24h, :map, required: true
  attr :alerts, :list, required: true
  attr :timezone, :string, default: "Etc/UTC"

  def gaps_and_alerts_card(assigns) do
    ~H"""
    <section
      id="recording-health-gaps-alerts-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-5"
    >
      <div id="health-gaps-24h-section" class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">
              24-Hour Recording Gaps by Reason (<code class="font-mono">A7</code>)
            </h2>
            <p class="mt-0.5 text-xs text-sr-muted">
              Grouped from <code class="font-mono">RecordingGap</code> rows over the trailing 24 hours
              plus any currently open gaps. Disabled or unscheduled policies are not gaps.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.ui_badge id="health-gaps-total-badge" size="xs" variant="ghost">
              24h total: {@gaps_24h.total_24h_count}
            </.ui_badge>
            <.ui_badge
              id="health-open-gaps-badge"
              size="xs"
              variant={if(@gaps_24h.open_gaps_count > 0, do: "warning", else: "ghost")}
            >
              Open gaps: {@gaps_24h.open_gaps_count}
            </.ui_badge>
          </div>
        </div>

        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
          <div
            :for={item <- @gaps_24h.reasons_with_counts}
            id={"health-gap-reason-#{item.reason}"}
            class={[
              "rounded-lg border px-3 py-2 text-xs flex items-center justify-between gap-2",
              if(item.count > 0,
                do: "border-amber-500/40 bg-amber-500/5 text-sr-ink",
                else: "border-sr-line bg-sr-subtle/20 text-sr-muted"
              )
            ]}
          >
            <span class="font-mono text-[11px] truncate">{item.reason}</span>
            <span class="font-mono font-semibold">{item.count}</span>
          </div>
        </div>

        <div
          :if={@gaps_24h.open_gaps != []}
          id="health-open-gaps-list"
          class="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 space-y-1 text-xs"
        >
          <div class="font-semibold text-sr-ink">Currently Open Gaps</div>
          <ul class="space-y-1 text-sr-muted">
            <li :for={gap <- @gaps_24h.open_gaps} id={"health-open-gap-#{gap.id}"}>
              <code class="font-mono text-sr-ink">{gap.reason}</code>
              <span :if={gap.detail_class}> (<code class="font-mono">{gap.detail_class}</code>)</span>
              · camera <span class="font-mono">{gap.camera_source_id || "—"}</span>
              · basis <code class="font-mono">{gap.time_basis}</code>
            </li>
          </ul>
        </div>
      </div>

      <div id="health-active-alerts-section" class="border-t border-sr-line pt-4 space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 class="text-sm font-semibold text-sr-ink">
              Active Storage &amp; NVR Health Alerts
            </h3>
            <p class="mt-0.5 text-xs text-sr-muted">
              Deduplicated <code class="font-mono">storage.recordings.*</code>
              and <code class="font-mono">nvr.*</code>
              checks recorded via <code class="font-mono">TripwireHealth</code>
              / <code class="font-mono">HealthTracker</code>.
            </p>
          </div>
          <.ui_badge
            id="health-alerts-count-badge"
            size="xs"
            variant={if(@alerts == [], do: "success", else: "error")}
          >
            {if @alerts == [], do: "0 active alerts", else: "#{length(@alerts)} active"}
          </.ui_badge>
        </div>

        <p
          :if={@alerts == []}
          id="health-alerts-empty"
          class="text-xs text-sr-muted"
        >
          No active <code class="font-mono">storage.recordings.*</code>
          or <code class="font-mono">nvr.*</code>
          health alerts in CNPG.
        </p>

        <ul :if={@alerts != []} id="health-active-alerts-list" class="space-y-2">
          <li
            :for={alert <- @alerts}
            id={"health-alert-#{sanitize_dom_id(alert.check_id)}"}
            class="rounded-lg border border-rose-500/40 bg-rose-500/5 p-3 text-xs space-y-1"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <.ui_badge size="xs" variant={alert_severity_variant(alert.severity)}>
                  {to_string(alert.severity)}
                </.ui_badge>
                <span class="font-mono font-semibold text-sr-ink">{alert.check_id}</span>
              </div>
              <span :if={alert.recorded_at} class="text-[11px] text-sr-muted">
                <.user_time
                  id={"health-alert-at-#{sanitize_dom_id(alert.check_id)}"}
                  value={alert.recorded_at}
                  timezone={@timezone}
                  style={:compact}
                />
              </span>
            </div>
            <p :if={alert.reason} class="text-sr-muted">{alert.reason}</p>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :visual_indexing, :map, default: %{}
  attr :timezone, :string, default: "Etc/UTC"

  def visual_indexing_card(assigns) do
    vi = assigns.visual_indexing || %{}
    active_model = fetch_val(vi, :active_model) || %{}

    model_id =
      fetch_val(vi, :model_id) ||
        fetch_val(active_model, :embedder_model_id) ||
        fetch_val(active_model, :model_id) ||
        "siglip-b16-384"

    model_version =
      fetch_val(vi, :model_version) ||
        fetch_val(active_model, :embedder_model_version) ||
        fetch_val(active_model, :model_version) ||
        "v1"

    embedding_dim =
      fetch_val(vi, :embedding_dim) ||
        fetch_val(active_model, :embedding_dim) ||
        768

    pending_count =
      int_or_zero(fetch_val(vi, :pending_count) || fetch_val(vi, :pending))

    dispatched_count =
      int_or_zero(
        fetch_val(vi, :dispatched_count) ||
          fetch_val(vi, :published_count) ||
          fetch_val(vi, :dispatched) ||
          fetch_val(vi, :published)
      )

    completed_count =
      int_or_zero(fetch_val(vi, :completed_count) || fetch_val(vi, :completed))

    failed_count =
      int_or_zero(
        fetch_val(vi, :failed_terminal_count) ||
          fetch_val(vi, :failed_count) ||
          fetch_val(vi, :failed)
      )

    enabled_policies = int_or_zero(fetch_val(vi, :enabled_policy_count))
    oldest_pending_at = fetch_val(vi, :oldest_pending_at)
    worker_status = to_string(fetch_val(vi, :worker_health_status) || :idle)

    assigns =
      assigns
      |> assign(:model_id, model_id)
      |> assign(:model_version, model_version)
      |> assign(:embedding_dim, embedding_dim)
      |> assign(:pending_count, pending_count)
      |> assign(:dispatched_count, dispatched_count)
      |> assign(:completed_count, completed_count)
      |> assign(:failed_count, failed_count)
      |> assign(:enabled_policies, enabled_policies)
      |> assign(:oldest_pending_at, oldest_pending_at)
      |> assign(:worker_status, worker_status)

    ~H"""
    <section
      id="health-visual-indexing-card"
      aria-label="Visual indexing and semantic search health"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Visual Indexing &amp; Semantic Clip Search (<code class="font-mono">VisualIndexJob</code>)
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Outbox job queue states for sealed blocks on policies with
            <code class="font-mono">visual_index_mode = keyframes</code>
            and active vision-language embedding model configuration.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-1.5">
          <.ui_badge
            id="health-visual-indexing-model-badge"
            size="xs"
            variant="info"
          >
            {@model_id} ({@model_version} · {@embedding_dim}-d)
          </.ui_badge>
          <.ui_badge
            id="health-visual-indexing-status-badge"
            size="xs"
            variant={if(@failed_count > 0, do: "warning", else: "ghost")}
          >
            {@worker_status} · {@enabled_policies} active policies
          </.ui_badge>
        </div>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div
          id="health-visual-jobs-pending"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Pending outbox</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">{@pending_count}</div>
          <div :if={@oldest_pending_at} class="mt-0.5 text-[11px] text-sr-muted">
            Oldest:
            <.user_time
              id="health-visual-oldest-pending-at"
              value={@oldest_pending_at}
              timezone={@timezone}
              style={:compact}
            />
          </div>
        </div>

        <div
          id="health-visual-jobs-dispatched"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Dispatched / in-flight</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">{@dispatched_count}</div>
        </div>

        <div
          id="health-visual-jobs-completed"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Completed</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">{@completed_count}</div>
        </div>

        <div
          id="health-visual-jobs-failed"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Failed terminal</div>
          <div class={[
            "mt-1 text-lg font-semibold font-mono",
            if(@failed_count > 0, do: "text-rose-500", else: "text-sr-ink")
          ]}>
            {@failed_count}
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :vantage_workers, :map, default: %{}
  attr :timezone, :string, default: "Etc/UTC"

  def vantage_workers_card(assigns) do
    vw = assigns.vantage_workers || %{}
    workers = List.wrap(Map.get(vw, :workers))
    pipelines = List.wrap(Map.get(vw, :pipelines))
    queue_lag = Map.get(vw, :queue_lag) || %{}
    online_count = int_or_zero(Map.get(vw, :online_count))
    stale_count = int_or_zero(Map.get(vw, :stale_count))
    routing_mode = Map.get(vw, :routing_mode, :idle)

    assigns =
      assigns
      |> assign(:workers, workers)
      |> assign(:pipelines, pipelines)
      |> assign(:queue_lag, queue_lag)
      |> assign(:online_count, online_count)
      |> assign(:stale_count, stale_count)
      |> assign(:routing_mode, routing_mode)

    ~H"""
    <section
      id="health-vantage-workers-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Vantage ML Workers &amp; Queue Health
          </h2>
          <p class="text-xs text-sr-muted">
            Live <code class="font-mono">vantage.worker.v1</code> capability registrations,
            queue lag, and dynamic Ramp 1 (<code class="font-mono">camera_vlm</code>) vs
            Ramp 2 (<code class="font-mono">vantage.worker.v1</code>) dispatch routing.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge
            id="health-vantage-routing-badge"
            size="xs"
            variant={vantage_routing_badge_variant(@routing_mode)}
          >
            {vantage_routing_badge_label(@routing_mode)}
          </.ui_badge>
          <.ui_badge size="xs" variant="outline">
            {@online_count} online / {@stale_count} stale
          </.ui_badge>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div
          id="health-vantage-queue-pending"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Pending jobs</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">
            {if(Map.get(@queue_lag, :accessible?, true),
              do: int_or_zero(Map.get(@queue_lag, :pending_count)),
              else: "restricted"
            )}
          </div>
        </div>

        <div
          id="health-vantage-queue-dispatched"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Dispatched / in-flight</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">
            {if(Map.get(@queue_lag, :accessible?, true),
              do: int_or_zero(Map.get(@queue_lag, :dispatched_count)),
              else: "restricted"
            )}
          </div>
        </div>

        <div
          id="health-vantage-queue-oldest-age"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3"
        >
          <div class="text-xs text-sr-muted">Oldest pending age</div>
          <div class="mt-1 text-lg font-semibold font-mono text-sr-ink">
            {format_oldest_pending_age(Map.get(@queue_lag, :oldest_pending_age_seconds))}
          </div>
        </div>
      </div>

      <p :if={@workers == []} id="health-vantage-workers-empty" class="text-xs text-sr-muted">
        No <code class="font-mono">vantage.worker.v1</code>
        worker heartbeats recorded yet. <code class="font-mono">recorded_block</code>
        pipelines with <code class="font-mono">fallback_runner = camera_vlm</code>
        automatically route to Ramp 1.
      </p>

      <div :if={@workers != []} class="overflow-x-auto">
        <table id="health-vantage-workers-table" class="w-full text-left text-xs">
          <thead class="border-b border-sr-line text-sr-muted">
            <tr>
              <th class="py-2 pr-3 font-medium">Worker</th>
              <th class="py-2 pr-3 font-medium">Capabilities &amp; Modes</th>
              <th class="py-2 pr-3 font-medium">Runtime &amp; Model</th>
              <th class="py-2 pr-3 font-medium">Concurrency</th>
              <th class="py-2 pr-3 font-medium">Health</th>
              <th class="py-2 font-medium">Expires</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-sr-line">
            <tr :for={w <- @workers} id={"health-vantage-worker-#{w.worker_id}"} class="align-top">
              <td class="py-2 pr-3 font-mono text-sr-ink">
                <div>{w.worker_id}</div>
                <div class="text-[11px] text-sr-muted">{w.worker_kind}</div>
              </td>
              <td class="py-2 pr-3">
                <div class="font-mono text-sr-ink">{Enum.join(w.capabilities, ", ")}</div>
                <div class="text-[11px] text-sr-muted">
                  modes: {Enum.join(w.supported_source_modes, ", ")}
                </div>
              </td>
              <td class="py-2 pr-3 font-mono text-sr-ink">
                <div>{w.execution_backend} / {w.architecture}</div>
                <div class="text-[11px] text-sr-muted">{w.model_id}:{w.model_version}</div>
              </td>
              <td class="py-2 pr-3 font-mono text-sr-ink">
                {w.active_jobs}/{w.max_concurrency}
              </td>
              <td class="py-2 pr-3">
                <.ui_badge
                  size="xs"
                  variant={if(w.online?, do: "success", else: "warning")}
                >
                  {if(w.stale?, do: "stale", else: w.health)}
                </.ui_badge>
              </td>
              <td class="py-2 font-mono text-[11px] text-sr-muted">
                <.user_time
                  :if={w.expires_at}
                  id={"health-vantage-worker-expires-#{sanitize_dom_id(w.worker_id)}"}
                  value={w.expires_at}
                  timezone={@timezone}
                  style={:compact}
                />
                <span :if={is_nil(w.expires_at)}>—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@pipelines != []} class="overflow-x-auto pt-1">
        <table id="health-vantage-pipelines-table" class="w-full text-left text-xs">
          <thead class="border-b border-sr-line text-sr-muted">
            <tr>
              <th class="py-1.5 pr-3 font-medium">Pipeline</th>
              <th class="py-1.5 pr-3 font-medium">Capability &amp; Source Mode</th>
              <th class="py-1.5 pr-3 font-medium">Active Route</th>
              <th class="py-1.5 font-medium">Ready Workers</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-sr-line">
            <tr :for={p <- @pipelines} class="align-top">
              <td class="py-1.5 pr-3 font-mono text-sr-ink">{p.pipeline_id} (v{p.version})</td>
              <td class="py-1.5 pr-3 font-mono text-sr-muted">
                {p.capability || "vantage.vlm.v1"} · {p.source_mode}
              </td>
              <td class="py-1.5 pr-3">
                <.ui_badge
                  size="xs"
                  variant={pipeline_route_badge_variant(p.active_route)}
                >
                  {pipeline_route_label(p.active_route)}
                </.ui_badge>
              </td>
              <td class="py-1.5 font-mono text-sr-ink">{p.worker_count}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp vantage_routing_badge_variant(:ramp_2), do: "success"
  defp vantage_routing_badge_variant(:mixed), do: "info"
  defp vantage_routing_badge_variant(:ramp_1_fallback), do: "warning"
  defp vantage_routing_badge_variant(:held), do: "error"
  defp vantage_routing_badge_variant(_), do: "ghost"

  defp vantage_routing_badge_label(:ramp_2), do: "Ramp 2: vantage.worker.v1 active"
  defp vantage_routing_badge_label(:mixed), do: "Mixed: Ramp 2 + Ramp 1 fallback"
  defp vantage_routing_badge_label(:ramp_1_fallback), do: "Ramp 1: camera_vlm active"
  defp vantage_routing_badge_label(:held), do: "Held (awaiting worker)"
  defp vantage_routing_badge_label(_), do: "Idle"

  defp pipeline_route_badge_variant(:ramp_2), do: "success"
  defp pipeline_route_badge_variant(:ramp_1_fallback), do: "warning"
  defp pipeline_route_badge_variant(:camera_vlm), do: "info"
  defp pipeline_route_badge_variant(_), do: "error"

  defp pipeline_route_label(:ramp_2), do: "Ramp 2 (vantage.worker.v1)"
  defp pipeline_route_label(:ramp_1_fallback), do: "Ramp 1 fallback (camera_vlm)"
  defp pipeline_route_label(:camera_vlm), do: "Ramp 1 (camera_vlm)"
  defp pipeline_route_label(_), do: "Held (no eligible worker)"

  defp format_oldest_pending_age(age) when is_integer(age), do: "#{age}s"
  defp format_oldest_pending_age(_), do: "—"

  # --- formatting helpers ----------------------------------------------------

  defp format_desired_budget(desired) do
    mode = fetch_val(desired, :budget_mode)
    bytes = fetch_val(desired, :budget_bytes)

    if mode in [:custom, "custom"] and is_integer(bytes) do
      "custom: #{format_bytes(bytes)} (#{bytes} B)"
    else
      "install_default (85% of PVC − reserve)"
    end
  end

  defp format_desired_reserve(desired) do
    mode = fetch_val(desired, :reserve_mode)
    bytes = fetch_val(desired, :reserve_bytes)

    if mode in [:custom, "custom"] and is_integer(bytes) do
      "custom: #{format_bytes(bytes)} (#{bytes} B)"
    else
      "install_default (max(64 MiB, 1%))"
    end
  end

  defp format_storage_revision_label(row) do
    rev = fetch_val(row.desired_settings, :revision)

    if row.persisted_settings? and is_integer(rev) and rev >= 1 do
      "rev #{rev}"
    else
      "install default"
    end
  end

  defp sync_badge_variant(row) do
    if row.persisted_settings? do
      case fetch_val(row.desired_settings, :sync_state) do
        s when s in [:applied, "applied"] -> "success"
        s when s in [:refused, "refused"] -> "error"
        _ -> "warning"
      end
    else
      "ghost"
    end
  end

  defp format_sync_badge_label(row) do
    if row.persisted_settings? do
      to_string(fetch_val(row.desired_settings, :sync_state) || :pending)
    else
      "install_default"
    end
  end

  defp format_applied_revision_note(row) do
    desired = row.desired_settings
    sync = fetch_val(desired, :sync_state)
    applied_rev = fetch_val(desired, :applied_revision)
    refusal = fetch_val(desired, :last_refusal_class)

    cond do
      not row.persisted_settings? ->
        "Using chart install defaults"

      sync in [:refused, "refused"] ->
        "Refused: #{refusal || "unknown"} (applied rev: #{applied_rev || "none"})"

      sync in [:applied, "applied"] ->
        "Applied rev #{applied_rev}"

      is_integer(applied_rev) ->
        "Applied rev #{applied_rev} (pending push)"

      true ->
        "Applied: awaiting member sync (C.14–C.16)"
    end
  end

  defp live_capacity_present?(member) do
    Map.get(member, :live_status_state) == :reported and
      is_map(Map.get(member, :live_status)) and
      (is_integer(live_field(member, :used_bytes)) or
         is_integer(live_field(member, :available_bytes)) or
         is_integer(live_field(member, :blocks)))
  end

  defp live_spool_bar_present?(member) do
    used = live_field(member, :used_bytes)
    max_spool = live_field(member, :max_spool_bytes)
    is_integer(used) and is_integer(max_spool) and max_spool > 0
  end

  defp live_used_percent(member) do
    case live_field(member, :used_percent) do
      pct when is_number(pct) ->
        pct |> max(0.0) |> min(100.0)

      _ ->
        used = live_field(member, :used_bytes) || 0
        max_spool = live_field(member, :max_spool_bytes) || 0

        if max_spool > 0 do
          used |> Kernel.*(100.0) |> Kernel./(max_spool) |> max(0.0) |> min(100.0) |> Float.round(1)
        else
          0.0
        end
    end
  end

  defp spool_bar_color(pct) when pct >= 90.0, do: "bg-rose-500"
  defp spool_bar_color(pct) when pct >= 80.0, do: "bg-amber-500"
  defp spool_bar_color(_pct), do: "bg-emerald-500"

  defp live_field(member, key) do
    case Map.get(member, :live_status) do
      %{} = live -> fetch_val(live, key)
      _ -> nil
    end
  end

  defp live_ledger_badge_variant(member) do
    drift = live_field(member, :drift_count)

    if Map.get(member, :live_status_state) == :reported do
      case Map.get(member, :ledger_state) do
        state when state in [:ready, "ready", :ok, "ok"] ->
          if is_integer(drift) and drift > 0, do: "warning", else: "success"

        state when state in [:mismatch, "mismatch", :degraded, "degraded", :unavailable, "unavailable"] ->
          "error"

        _ ->
          "warning"
      end
    else
      "warning"
    end
  end

  defp format_live_ledger_status(member) do
    drift = live_field(member, :drift_count)

    if Map.get(member, :live_status_state) == :reported and
         Map.get(member, :ledger_state) not in [nil, :unknown_until_nvr_status] do
      case Map.get(member, :ledger_state) do
        state when state in [:ready, "ready", :ok, "ok"] ->
          if is_integer(drift) and drift > 0,
            do: "degraded (drift: #{drift})",
            else: "ok"

        state when state in [:mismatch, "mismatch"] ->
          if is_integer(drift) and drift > 0,
            do: "degraded (mismatch, drift: #{drift})",
            else: "degraded (mismatch)"

        state when state in [:degraded, "degraded"] ->
          if is_integer(drift) and drift > 0,
            do: "degraded (drift: #{drift})",
            else: "degraded"

        other ->
          to_string(other)
      end
    else
      "unknown until NVR /v1/status reports"
    end
  end

  defp format_disposition_reasons(pairs) do
    Enum.map_join(pairs, ", ", fn {reason, count} -> "#{reason}: #{count}" end)
  end

  defp alert_severity_variant(sev) when sev in [:critical, "critical", :error, "error"], do: "error"

  defp alert_severity_variant(sev) when sev in [:warning, "warning"], do: "warning"
  defp alert_severity_variant(_), do: "info"

  defp sanitize_dom_id(str) do
    str |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp format_age_seconds(nil), do: "None"

  defp format_age_seconds(sec) when is_integer(sec) and sec >= 3_600 do
    "#{format_num(sec / 3_600.0)} hours (#{sec} s)"
  end

  defp format_age_seconds(sec) when is_integer(sec) and sec >= 60 do
    "#{format_num(sec / 60.0)} minutes (#{sec} s)"
  end

  defp format_age_seconds(sec) when is_integer(sec), do: "#{sec} s"
  defp format_age_seconds(_), do: "None"

  defp format_local_window_summary(local_proj) do
    status = Map.get(local_proj, :status, :not_recording)
    low = Map.get(local_proj, :window_low_seconds, 0.0)
    high = Map.get(local_proj, :window_high_seconds, 0.0)
    bound = Map.get(local_proj, :binding_bound, :budget)

    cond do
      status == :not_recording ->
        "Not recording — no active camera rate or recent catalog blocks"

      low == :until_policy_or_age_changes ->
        "Pinned under stop_when_full (kept until full policy or max age changes)"

      low == :infinity ->
        "Local storage holds unlimited at the current rate"

      is_number(low) and is_number(high) ->
        est_note = if status == :estimated, do: ", estimated", else: ""

        "Local storage holds about #{format_window_range(low, high)} at the current rate (#{format_bound_text(bound)}#{est_note})"

      true ->
        "Not recording"
    end
  end

  defp format_window_range(low_sec, high_sec) when is_number(low_sec) and is_number(high_sec) do
    cond do
      high_sec <= 0.0 ->
        "0 minutes"

      abs(high_sec - low_sec) < 1.0 ->
        format_span(low_sec)

      high_sec < 3_600.0 ->
        "#{format_num(low_sec / 60.0)} to #{format_num(high_sec / 60.0)} minutes"

      true ->
        "#{format_num(low_sec / 3_600.0)} to #{format_num(high_sec / 3_600.0)} hours"
    end
  end

  defp format_span(seconds) when seconds < 3_600.0, do: "#{format_num(seconds / 60.0)} minutes"
  defp format_span(seconds), do: "#{format_num(seconds / 3_600.0)} hours"

  defp format_bound_text(:max_age), do: "maximum age binds"
  defp format_bound_text(:block_cap), do: "block cap binds"
  defp format_bound_text(:pinned), do: "pinned under stop_when_full"
  defp format_bound_text(_), do: "budget binds"

  defp format_local_bound_badge(:not_recording), do: "Not recording"
  defp format_local_bound_badge(:max_age), do: "Age ceiling"
  defp format_local_bound_badge(:block_cap), do: "Block cap"
  defp format_local_bound_badge(:pinned), do: "Pinned"
  defp format_local_bound_badge(_), do: "Budget"

  defp format_time_to_full(:not_filling), do: "not filling"
  defp format_time_to_full(sec) when is_number(sec), do: "about #{format_span(sec)}"
  defp format_time_to_full(_), do: "not filling"

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_073_741_824 do
    "#{format_num(bytes / 1_073_741_824)} GiB"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_048_576 do
    "#{format_num(bytes / 1_048_576)} MiB"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_024 do
    "#{format_num(bytes / 1_024)} KiB"
  end

  defp format_bytes(bytes) when is_number(bytes), do: "#{trunc(bytes)} B"
  defp format_bytes(_), do: "0 B"

  defp format_num(val) when is_number(val) do
    rounded = Float.round(val * 1.0, 1)

    if rounded == Float.floor(rounded) do
      rounded |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  defp format_num(_), do: "0"

  defp extract_reservations_breakdown(health_summary) when is_map(health_summary) do
    raw = Map.get(health_summary, :reservations, %{})
    by_state = Map.get(raw, :by_state, %{})

    unresolved =
      int_or_zero(fetch_val(raw, :unresolved_count) || fetch_val(by_state, :unresolved))

    adopted = int_or_zero(fetch_val(raw, :adopted_count) || fetch_val(by_state, :adopted))

    absent =
      int_or_zero(fetch_val(raw, :block_absent_count) || fetch_val(by_state, :block_absent))

    unrecoverable =
      int_or_zero(
        fetch_val(raw, :unrecoverable_journal_count) ||
          fetch_val(raw, :unrecoverable_count) ||
          fetch_val(by_state, :unrecoverable_journal)
      )

    total =
      case fetch_val(raw, :total_count) do
        n when is_integer(n) and n > 0 -> n
        _ -> unresolved + adopted + absent + unrecoverable
      end

    %{
      total_count: total,
      unresolved_count: unresolved,
      adopted_count: adopted,
      block_absent_count: absent,
      unrecoverable_journal_count: unrecoverable
    }
  end

  defp extract_reservations_breakdown(_), do: extract_reservations_breakdown(%{})

  defp resolve_quarantined_rows(health_summary, backlog) do
    top_q = List.wrap(Map.get(health_summary, :quarantined_entries))
    backlog_q = List.wrap(Map.get(backlog, :quarantined_entries))
    top_u = List.wrap(Map.get(health_summary, :unattributable_blocks))
    backlog_u = List.wrap(Map.get(backlog, :unattributable_blocks))

    base = if top_q == [], do: backlog_q, else: top_q

    (base ++ top_u ++ backlog_u)
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_quarantined_row/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp normalize_quarantined_row(row) when is_map(row) do
    id = to_string(fetch_val(row, :id) || fetch_val(row, :catalog_entry_id) || fetch_val(row, :block_key))
    recorded_at = fetch_val(row, :recorded_at) || fetch_val(row, :local_state_at) || fetch_val(row, :sealed_at)

    %{
      id: id,
      storage_id: fetch_val(row, :storage_id),
      block_key: fetch_val(row, :block_key) || id,
      quarantine_reason: fetch_val(row, :quarantine_reason) || :quarantined,
      quarantined_bytes: int_or_zero(fetch_val(row, :quarantined_bytes)),
      evidence_summary: fetch_val(row, :evidence_summary),
      quarantine_evidence: fetch_val(row, :quarantine_evidence) || %{},
      local_state: fetch_val(row, :local_state) || :quarantined,
      archive_state: fetch_val(row, :archive_state) || :not_required,
      operator_disposition_state: fetch_val(row, :operator_disposition_state) || :awaiting_operator,
      operator_decision: fetch_val(row, :operator_decision),
      recorded_at: recorded_at
    }
  end

  defp resolve_missing_archive_rows(health_summary, backlog) do
    top_m = List.wrap(Map.get(health_summary, :missing_archive_entries))
    backlog_m = List.wrap(Map.get(backlog, :missing_entries))
    rows = if top_m == [], do: backlog_m, else: top_m

    rows
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&to_string(fetch_val(&1, :id) || fetch_val(&1, :catalog_entry_id)))
  end

  defp format_quarantine_row_evidence(q) do
    cond do
      is_binary(q.evidence_summary) and q.evidence_summary != "" ->
        q.evidence_summary

      is_map(q.quarantine_evidence) and map_size(q.quarantine_evidence) > 0 ->
        detail =
          fetch_val(q.quarantine_evidence, :reason) ||
            fetch_val(q.quarantine_evidence, :detail_class) ||
            fetch_val(q.quarantine_evidence, :verification_class)

        if is_binary(detail) and detail != "",
          do: "Evidence: #{detail}",
          else: "Quarantined evidence recorded"

      true ->
        "Quarantined evidence recorded"
    end
  end

  defp format_quarantine_disposition_label(q) do
    case fetch_val(q, :operator_disposition_state) do
      s when s in [:delete_requested, "delete_requested"] -> "delete_requested"
      s when s in [:export_requested, "export_requested"] -> "export_requested"
      s when s in [:disposed, "disposed"] -> "disposed"
      _ -> "awaiting_operator"
    end
  end

  defp quarantine_disposition_badge_variant(q) do
    case format_quarantine_disposition_label(q) do
      "delete_requested" -> "error"
      "export_requested" -> "info"
      "disposed" -> "ghost"
      _ -> "warning"
    end
  end

  defp quarantine_decision_note(q) do
    case fetch_val(q, :operator_decision) do
      decision when is_map(decision) ->
        note = fetch_val(decision, :note)
        actor_id = fetch_val(decision, :actor_id)

        cond do
          is_binary(note) and note != "" and is_binary(actor_id) and actor_id != "" ->
            "Note: #{note} (by #{actor_id})"

          is_binary(note) and note != "" ->
            "Note: #{note}"

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp quarantine_row_actionable?(q) do
    local = fetch_val(q, :local_state)
    disp = format_quarantine_disposition_label(q)

    local in [:quarantined, "quarantined"] and disp not in ["delete_requested", "disposed"]
  end

  defp quarantine_exportable?(q) do
    quarantine_row_actionable?(q) and format_quarantine_disposition_label(q) != "export_requested"
  end

  defp format_quarantine_action_locked(q) do
    case format_quarantine_disposition_label(q) do
      "delete_requested" -> "Delete intent recorded (awaiting NVR reclaim)"
      "disposed" -> "Disposed"
      _ -> "Reclaiming"
    end
  end

  defp int_or_zero(val) when is_integer(val), do: val
  defp int_or_zero(val) when is_float(val), do: trunc(val)
  defp int_or_zero(_), do: 0

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
