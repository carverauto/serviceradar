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
            bound, pinned-growth <code class="font-mono">time_to_full</code>, and assigned continuous
            cameras per NVR storage UUID. Live NVR disk usage and inventory ledger audit state are
            reported as <strong>unknown until NVR /v1/status reports</strong>.
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

          <div class="flex flex-wrap items-center gap-2 pt-1 text-[11px] text-sr-muted">
            <.ui_badge size="xs" variant="warning">
              Disk &amp; ledger: {format_live_ledger_status(member)}
            </.ui_badge>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :backlog, :map, required: true
  attr :dispositions, :map, required: true
  attr :can_operate?, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def reconciliation_and_dispositions_card(assigns) do
    reason_pairs =
      assigns.dispositions
      |> Map.get(:by_reason_24h, %{})
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)

    assigns = assign(assigns, :reason_pairs, reason_pairs)

    ~H"""
    <section
      id="recording-health-reconciliation-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Reconciliation, Quarantine &amp; Retention Dispositions
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Quarantined and unattributable catalog entries, 24-hour append-only
            <code class="font-mono">RecordingDisposition</code>
            counts and failures, and held/missing
            archive state.
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
            Pinned as row (q), excluded from playback &amp; eviction
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
            if(@dispositions.held_archive_missing_count > 0 or @backlog.missing_count > 0,
              do: "border-rose-500/40 bg-rose-500/10",
              else: "border-sr-line bg-sr-subtle/30"
            )
          ]}
        >
          <div class="text-xs text-sr-muted">Holds &amp; missing archive copies</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            Held missing: {@dispositions.held_archive_missing_count} · Archive missing: {@backlog.missing_count}
          </div>
          <div class="text-[11px] text-sr-muted">
            Active holds: {@dispositions.active_hold_count}
          </div>
        </div>
      </div>

      <div :if={@backlog.quarantined_entries != []} id="health-quarantined-list" class="space-y-2">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="text-xs font-semibold text-sr-ink">Quarantined Catalog Entries</h3>
          <span class="text-[11px] text-sr-muted">
            {if @can_operate?,
              do: "Operator quarantine reclaim activates with C.6 / R.7",
              else: "Operator disposition requires settings.recording.operate"}
          </span>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-xs">
            <thead class="border-b border-sr-line text-sr-muted">
              <tr>
                <th class="py-1.5 pr-3 font-medium">Block Key</th>
                <th class="py-1.5 pr-3 font-medium">Storage ID</th>
                <th class="py-1.5 pr-3 font-medium">Reason</th>
                <th class="py-1.5 pr-3 font-medium">Bytes</th>
                <th class="py-1.5 font-medium">Archive State</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-sr-line">
              <tr
                :for={q <- @backlog.quarantined_entries}
                id={"health-quarantined-entry-#{q.id}"}
              >
                <td class="py-2 pr-3 font-mono text-sr-ink">{q.block_key}</td>
                <td class="py-2 pr-3 font-mono text-[11px] text-sr-muted">{q.storage_id || "—"}</td>
                <td class="py-2 pr-3">
                  <.ui_badge size="xs" variant="error">
                    {to_string(q.quarantine_reason || :quarantined)}
                  </.ui_badge>
                </td>
                <td class="py-2 pr-3 font-mono text-sr-ink">{format_bytes(q.quarantined_bytes)}</td>
                <td class="py-2 font-mono text-sr-muted">{to_string(q.archive_state)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div
        :if={@backlog.missing_entries != []}
        id="health-missing-archive-list"
        class="rounded-lg border border-rose-500/40 bg-rose-500/5 p-3 space-y-1.5"
      >
        <div class="text-xs font-semibold text-sr-ink">
          Catalog Entries Reporting <code class="font-mono">archive_state = missing</code>
        </div>
        <ul class="space-y-1 text-xs text-sr-muted">
          <li :for={m <- @backlog.missing_entries} id={"health-missing-entry-#{m.id}"}>
            <span class="font-mono text-sr-ink">{m.block_key}</span>
            · local: <code class="font-mono">{to_string(m.local_state)}</code>
            · {format_bytes(m.media_bytes)}
            <span :if={m.held?} class="font-semibold text-rose-500"> · HELD</span>
          </li>
        </ul>
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

  defp format_live_ledger_status(member) do
    if member.live_status_state == :reported and
         member.ledger_state not in [nil, :unknown_until_nvr_status] do
      to_string(member.ledger_state)
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

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
