defmodule ServiceRadarWebNGWeb.Settings.RecordingLive.PolicyComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Camera.CameraRecordingPolicies

  attr :storage_mode, :atom, default: :local_only

  def runtime_notice(assigns) do
    ~H"""
    <section
      id="recording-policy-runtime-notice"
      class="rounded-xl border border-sr-line bg-sr-subtle/40 p-4 space-y-2"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <.icon name="hero-video-camera" class="size-4 text-sr-ink" />
          <h2 class="text-sm font-semibold text-sr-ink">
            Per-Camera Continuous Recording Policy &amp; Pre-Save Capacity Projection
          </h2>
        </div>
        <.ui_badge
          id="policy-storage-mode-badge"
          size="xs"
          variant={if(@storage_mode == :local_and_archive, do: "success", else: "ghost")}
        >
          {if @storage_mode == :local_and_archive,
            do: "Local + archive",
            else: "Local only: no object storage configured"}
        </.ui_badge>
      </div>
      <p class="text-xs text-sr-muted">
        Saving a policy persists an audited <code class="font-mono">CameraRecordingPolicy</code>
        revision (<code class="font-mono">platform.camera_recording_policies</code>) in CNPG today,
        treating every edit as an assignment transition (<code class="font-mono">policy_revision</code>).
        Continuous capture execution starts once <code class="font-mono">ContinuousRecorder</code>
        (<code class="font-mono">A.3.1</code>) workers are active on <code class="font-mono">core-elx</code>.
        Recorded media is packaged without general-purpose recompression.
      </p>
    </section>
    """
  end

  attr :policies, :list, required: true
  attr :recording_now, :any, default: MapSet.new()
  attr :sources, :list, required: true
  attr :entitlement, :map, default: %{}
  attr :can_manage?, :boolean, required: true

  def policies_table_card(assigns) do
    sources_by_id =
      Map.new(assigns.sources, fn src -> {to_string(Map.get(src, :id)), src} end)

    entitlement_applied? = Map.get(assigns.entitlement, :applied?) == true
    max_cameras = if entitlement_applied?, do: Map.get(assigns.entitlement, :max_recording_cameras)
    plan_max_days = if entitlement_applied?, do: Map.get(assigns.entitlement, :retention_max_days)

    enabled_continuous_count =
      Enum.count(assigns.policies, &(fetch_val(&1, :mode) in [:continuous, "continuous"]))

    assigns =
      assigns
      |> assign(:sources_by_id, sources_by_id)
      |> assign(:max_cameras, max_cameras)
      |> assign(:plan_max_days, plan_max_days)
      |> assign(:enabled_continuous_count, enabled_continuous_count)

    ~H"""
    <section
      id="recording-policies-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Configured Camera Recording Policies</h2>
          <p class="mt-1 text-xs text-sr-muted">
            One policy per camera source and relay-eligible stream profile. Inspect bitrate-derived
            daily storage and block estimates, NVR member assignment, storage tier, per-policy
            archive retention override, and <code class="font-mono">policy_revision</code>.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-1.5">
          <.ui_badge
            :if={is_integer(@max_cameras)}
            id="policy-camera-limit-badge"
            size="xs"
            variant={if(@enabled_continuous_count >= @max_cameras, do: "warning", else: "info")}
          >
            {@enabled_continuous_count} / {@max_cameras} continuous cameras (limited by your plan)
          </.ui_badge>
          <.ui_badge size="xs" variant="ghost">{length(@policies)} configured</.ui_badge>
        </div>
      </div>

      <p
        :if={@policies == []}
        id="recording-policies-empty"
        class="text-sm text-sr-muted"
      >
        No per-camera recording policies saved in CNPG yet.
      </p>

      <div :if={@policies != []} class="overflow-x-auto">
        <table id="recording-policies-table" class="w-full text-left text-xs">
          <thead class="border-b border-sr-line text-sr-muted">
            <tr>
              <th class="py-2 pr-3 font-medium">Camera &amp; Stream Profile</th>
              <th class="py-2 pr-3 font-medium">Profile Bitrate &amp; Daily Estimate</th>
              <th class="py-2 pr-3 font-medium">Mode</th>
              <th class="py-2 pr-3 font-medium">NVR Member</th>
              <th class="py-2 pr-3 font-medium">Storage</th>
              <th class="py-2 pr-3 font-medium">Archive Retention Override</th>
              <th class="py-2 pr-3 font-medium">Visual Indexing</th>
              <th class="py-2 pr-3 font-medium">Revision</th>
              <th :if={@can_manage?} class="py-2 font-medium">Action</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-sr-line">
            <tr
              :for={policy <- @policies}
              id={"recording-policy-row-#{fetch_val(policy, :id)}"}
              class="align-top"
            >
              <td class="py-2.5 pr-3">
                <div class="font-medium text-sr-ink">
                  {policy_camera_label(policy, @sources_by_id)}
                </div>
                <div class="mt-0.5 font-mono text-[11px] text-sr-muted">
                  {policy_profile_label(policy)}
                </div>
              </td>
              <td class="py-2.5 pr-3 text-sr-ink">
                {format_policy_row_estimate(policy)}
              </td>
              <td class="py-2.5 pr-3">
                <.ui_badge
                  id={"policy-recording-state-#{fetch_val(policy, :id)}"}
                  size="xs"
                  variant={policy_mode_variant(policy, @recording_now)}
                >
                  {policy_mode_label(policy, @recording_now)}
                </.ui_badge>
              </td>
              <td class="py-2.5 pr-3 font-mono text-sr-ink">
                {fetch_val(policy, :nvr_member) || "—"}
              </td>
              <td class="py-2.5 pr-3 font-mono text-sr-ink">
                {to_string(fetch_val(policy, :storage) || :local_only)}
              </td>
              <td class="py-2.5 pr-3 text-sr-ink">
                {format_override_label(policy, @plan_max_days)}
              </td>
              <td class="py-2.5 pr-3 text-sr-ink">
                <.ui_badge
                  size="xs"
                  variant={
                    if(fetch_val(policy, :visual_index_mode) in [:keyframes, "keyframes"],
                      do: "info",
                      else: "ghost"
                    )
                  }
                >
                  {format_visual_index_summary(policy)}
                </.ui_badge>
              </td>
              <td class="py-2.5 pr-3">
                <.ui_badge
                  id={"policy-revision-#{fetch_val(policy, :id)}"}
                  size="xs"
                  variant="outline"
                >
                  rev {fetch_val(policy, :policy_revision) || 1}
                </.ui_badge>
              </td>
              <td :if={@can_manage?} class="py-2.5">
                <.ui_button
                  id={"edit-policy-#{fetch_val(policy, :id)}"}
                  type="button"
                  phx-click="edit_policy"
                  phx-value-id={to_string(fetch_val(policy, :id))}
                  variant="outline"
                  size="xs"
                >
                  Edit
                </.ui_button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :what_if, :map, required: true
  attr :storage_mode, :atom, default: :local_only
  attr :editing_revision, :any, default: nil

  def what_if_card(assigns) do
    warnings = Map.get(assigns.what_if, :warnings, [])
    unmeasured_active? = unmeasured_active_what_if?(assigns.what_if, warnings)

    hazard_warnings =
      warnings
      |> Enum.reject(&(&1 == :unknown_profile_bitrate))
      |> then(fn list ->
        if unmeasured_active?, do: Enum.reject(list, &(&1 == :local_window_below_alert)), else: list
      end)

    show_unmeasured_note? = :unknown_profile_bitrate in warnings
    local_proj = Map.get(assigns.what_if, :local_projection, %{})
    cand_obj = Map.get(assigns.what_if, :candidate_object_policy)
    obj_proj = Map.get(assigns.what_if, :object_projection, %{})

    assigns =
      assigns
      |> assign(:hazard_warnings, hazard_warnings)
      |> assign(:show_unmeasured_note?, show_unmeasured_note?)
      |> assign(:unmeasured_active?, unmeasured_active?)
      |> assign(:local_proj, local_proj)
      |> assign(:cand_obj, cand_obj)
      |> assign(:obj_proj, obj_proj)

    ~H"""
    <section
      id="recording-policy-what-if-panel"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Pre-Save What-If Capacity &amp; Throughput Projection (<code class="font-mono">C1a</code>)
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Updates live on <code class="font-mono">phx-change="preview_policy"</code> before saving:
            projected local window on the target member, required archive throughput (~2x capture
            rate) vs measured throughput, blocks/day vs volume cap, active continuous sessions vs
            member limit, and object-tier effective retention.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge id="what-if-target-member-badge" size="xs" variant="ghost">
            Member: {@what_if.nvr_member || "unselected"}
          </.ui_badge>
          <.ui_badge id="what-if-revision-badge" size="xs" variant="outline">
            {if is_integer(@editing_revision),
              do: "Revision #{@editing_revision} → #{@editing_revision + 1}",
              else: "New policy → revision 1"}
          </.ui_badge>
        </div>
      </div>

      <div
        :if={@hazard_warnings != []}
        id="policy-what-if-warnings"
        role="status"
        class="rounded-xl border border-amber-500/40 bg-amber-500/5 p-4 space-y-1.5 text-xs text-sr-ink"
      >
        <p class="font-semibold">Pre-save advisory warnings (non-blocking):</p>
        <ul class="list-disc pl-5 space-y-1">
          <li :for={warn <- @hazard_warnings} id={"policy-warning-#{warn}"}>
            {format_what_if_warning(warn, @what_if)}
          </li>
        </ul>
      </div>

      <div
        :if={@show_unmeasured_note?}
        id="policy-unmeasured-bitrate-note"
        class="rounded-xl border border-sr-line bg-sr-subtle/40 px-4 py-3 text-xs text-sr-muted"
      >
        Stream bitrate will be measured automatically once recording starts, or enter an optional
        simulated nominal bitrate (kbit/s) below to preview capacity impact.
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div
          id="what-if-local-window"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="flex items-center justify-between gap-1">
            <span class="text-xs text-sr-muted">Projected local window</span>
            <.ui_badge size="xs" variant="ghost">
              {if @unmeasured_active?,
                do: "Unmeasured",
                else: format_local_bound_badge(Map.get(@local_proj, :binding_bound))}
            </.ui_badge>
          </div>
          <div class="text-xs font-semibold text-sr-ink">
            {if @unmeasured_active?,
              do: "Unknown until recorded",
              else: format_local_window_summary(@local_proj)}
          </div>
          <div class="text-[11px] text-sr-muted">
            Time-to-full: {format_time_to_full(Map.get(@local_proj, :time_to_full_seconds))}
          </div>
        </div>

        <div
          id="what-if-archive-throughput"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Archive throughput (~2x capture)</div>
          <div class="text-xs font-semibold font-mono text-sr-ink">
            {if @unmeasured_active?,
              do: "Pending first recording",
              else:
                "Needed: #{format_rate_per_sec(@what_if.provider_throughput_needed_bytes_per_sec)}"}
          </div>
          <div class="text-[11px] text-sr-muted">
            {format_measured_throughput(
              @what_if.measured_provider_throughput_bytes_per_sec,
              @what_if.measured_archive_goodput_bytes_per_sec
            )}
          </div>
        </div>

        <div
          id="what-if-blocks-per-day"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Projected blocks / day</div>
          <div class="text-xs font-semibold font-mono text-sr-ink">
            {if @unmeasured_active?,
              do: "Unknown until recorded",
              else: "#{format_num(@what_if.projected_blocks_per_day)} blocks/day"}
          </div>
          <div class="text-[11px] text-sr-muted">
            Volume block cap: <span class="font-mono">{@what_if.max_blocks}</span> blocks
          </div>
        </div>

        <div
          id="what-if-member-sessions"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="flex items-center justify-between gap-1">
            <span class="text-xs text-sr-muted">Member sessions</span>
            <.ui_badge
              size="xs"
              variant={if(@what_if.sessions_exceed_limit?, do: "warning", else: "ghost")}
            >
              limit {@what_if.max_sessions}
            </.ui_badge>
          </div>
          <div class="text-xs font-semibold font-mono text-sr-ink">
            {@what_if.projected_sessions} / {@what_if.max_sessions} sessions
          </div>
          <div class="text-[11px] text-sr-muted">
            Continuous policies on member
          </div>
        </div>

        <div
          id="what-if-object-retention"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Object effective retention</div>
          <div class="text-xs font-semibold text-sr-ink">
            {format_candidate_object_retention(@cand_obj, @obj_proj, @storage_mode)}
          </div>
          <div class="text-[11px] text-sr-muted">
            Days to capacity: {format_days_to_capacity(Map.get(@obj_proj, :days_to_capacity))}
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :runtime, :map, default: %{}
  attr :policies, :list, default: []
  attr :entitlement, :map, default: %{}
  attr :can_manage?, :boolean, required: true
  attr :sources, :list, required: true
  attr :sources_forbidden?, :boolean, required: true
  attr :policy_profiles, :list, required: true
  attr :policy_form, :map, required: true
  attr :policy_editing_revision, :any, default: nil
  attr :policy_errors, :map, default: %{}

  def editor_form_card(assigns) do
    profile_rows =
      Enum.map(assigns.policy_profiles, fn prof ->
        %{profile: prof, estimate: CameraRecordingPolicies.profile_estimate(prof)}
      end)

    member_options =
      build_member_options(assigns.runtime, assigns.policies, assigns.policy_form)

    core_elx_unreachable? =
      get_in(assigns.runtime, [:core_elx, :reachability]) == :unreachable

    entitlement_applied? = Map.get(assigns.entitlement, :applied?) == true
    plan_max_days = if entitlement_applied?, do: Map.get(assigns.entitlement, :retention_max_days)
    max_cameras = if entitlement_applied?, do: Map.get(assigns.entitlement, :max_recording_cameras)

    enabled_continuous_count =
      Enum.count(assigns.policies, &(fetch_val(&1, :mode) in [:continuous, "continuous"]))

    assigns =
      assigns
      |> assign(:profile_rows, profile_rows)
      |> assign(:member_options, member_options)
      |> assign(:core_elx_unreachable?, core_elx_unreachable?)
      |> assign(:plan_max_days, plan_max_days)
      |> assign(:max_cameras, max_cameras)
      |> assign(:enabled_continuous_count, enabled_continuous_count)

    ~H"""
    <section
      id="recording-policy-editor-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            {if @policy_form["id"] != "",
              do: "Edit Camera Recording Policy",
              else: "Configure Camera Recording Policy"}
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Select a camera and relay-eligible stream profile, choose recording mode, NVR member
            assignment, storage mode, and optional archive retention override.
          </p>
        </div>
        <.ui_button
          :if={@can_manage? and @policy_form["id"] != ""}
          id="reset-policy-form-btn"
          type="button"
          phx-click="reset_policy_form"
          variant="outline"
          size="xs"
        >
          New policy
        </.ui_button>
      </div>

      <p
        :if={@sources_forbidden?}
        id="recording-policy-devices-permission-note"
        class="text-xs text-amber-500"
      >
        Listing camera sources and stream profiles additionally requires <code class="font-mono">devices.view</code>.
      </p>

      <form
        id="recording-policy-form"
        phx-change="preview_policy"
        phx-submit="save_policy"
        class="space-y-4"
      >
        <input type="hidden" name="policy[id]" value={@policy_form["id"]} />
        <input
          :if={@policy_form["id"] != ""}
          type="hidden"
          name="policy[camera_source_id]"
          value={@policy_form["camera_source_id"]}
        />
        <input
          :if={@policy_form["id"] != ""}
          type="hidden"
          name="policy[stream_profile_id]"
          value={@policy_form["stream_profile_id"]}
        />

        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label for="policy-camera-select" class="block text-xs font-medium text-sr-ink">
              Camera source
            </label>
            <select
              id="policy-camera-select"
              name="policy[camera_source_id]"
              disabled={!@can_manage? or @policy_form["id"] != ""}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option value="" selected={@policy_form["camera_source_id"] in [nil, ""]}>
                Select a camera
              </option>
              <option
                :for={source <- @sources}
                value={source.id}
                selected={@policy_form["camera_source_id"] == to_string(source.id)}
              >
                {source.display_name || source.vendor_camera_id} ({source.device_uid})
              </option>
            </select>
            <p
              :if={@policy_errors[:camera_source_id]}
              id="policy-error-camera-source"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:camera_source_id]}
            </p>
          </div>

          <div>
            <label for="policy-profile-select" class="block text-xs font-medium text-sr-ink">
              Relay-eligible stream profile
            </label>
            <select
              id="policy-profile-select"
              name="policy[stream_profile_id]"
              disabled={
                !@can_manage? or @policy_form["camera_source_id"] in [nil, ""] or
                  @policy_form["id"] != ""
              }
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                :if={@profile_rows == []}
                value=""
                selected
              >
                No relay-eligible profiles
              </option>
              <option
                :for={item <- @profile_rows}
                value={item.profile.id}
                selected={@policy_form["stream_profile_id"] == to_string(item.profile.id)}
              >
                {format_profile_option_label(item.profile, item.estimate)}
              </option>
            </select>
            <p
              :if={@policy_errors[:stream_profile_id]}
              id="policy-error-stream-profile"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:stream_profile_id]}
            </p>
          </div>
        </div>

        <div
          :if={@profile_rows != []}
          id="policy-profile-estimates"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1.5"
        >
          <div class="text-xs font-medium text-sr-ink">
            Available Relay-Eligible Stream Profile Storage Estimates
          </div>
          <div class="grid gap-2 sm:grid-cols-2">
            <div
              :for={item <- @profile_rows}
              id={"policy-profile-estimate-#{item.profile.id}"}
              class="rounded border border-sr-line bg-sr-surface px-3 py-2 text-xs"
            >
              <div class="font-medium text-sr-ink">
                {item.profile.profile_name}
                <span class="font-mono text-[11px] text-sr-muted">
                  ({item.profile.codec_hint || "h264"})
                </span>
              </div>
              <div class="mt-0.5 text-[11px] text-sr-muted">
                {format_estimate_line(item.estimate)}
              </div>
            </div>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <label for="policy-mode-select" class="block text-xs font-medium text-sr-ink">
              Recording mode
            </label>
            <select
              id="policy-mode-select"
              name="policy[mode]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option value="off" selected={@policy_form["mode"] == "off"}>off</option>
              <option value="continuous" selected={@policy_form["mode"] == "continuous"}>
                continuous
              </option>
            </select>
            <p
              :if={is_integer(@max_cameras)}
              id="policy-camera-plan-limit-note"
              class="mt-1 text-xs text-sr-muted"
            >
              {@enabled_continuous_count} of {@max_cameras} continuous cameras enabled — limited by your plan.
            </p>
            <p
              :if={@policy_errors[:mode]}
              id="policy-error-mode"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:mode]}
            </p>
          </div>

          <div>
            <label for="policy-nvr-member-select" class="block text-xs font-medium text-sr-ink">
              Assigned NVR member
            </label>
            <select
              id="policy-nvr-member-select"
              name="policy[nvr_member]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            >
              <option
                value=""
                selected={!Enum.any?(@member_options, &(&1.value == @policy_form["nvr_member"]))}
              >
                {cond do
                  @member_options != [] -> "Select an NVR member"
                  @core_elx_unreachable? -> "No NVR members discovered (core-elx unreachable)"
                  true -> "No NVR members discovered (core-elx unreachable)"
                end}
              </option>
              <option
                :for={opt <- @member_options}
                value={opt.value}
                selected={@policy_form["nvr_member"] == opt.value}
              >
                {opt.label}
              </option>
            </select>
            <p
              :if={@policy_errors[:nvr_member]}
              id="policy-error-nvr-member"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:nvr_member]}
            </p>
          </div>

          <div>
            <label for="policy-storage-select" class="block text-xs font-medium text-sr-ink">
              Storage tier
            </label>
            <select
              id="policy-storage-select"
              name="policy[storage]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                value="local_and_archive"
                selected={@policy_form["storage"] == "local_and_archive"}
              >
                local_and_archive — local spool + S3 archive after seal
              </option>
              <option value="local_only" selected={@policy_form["storage"] == "local_only"}>
                local_only — local spool only (not_required)
              </option>
            </select>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <label for="policy-override-mode-select" class="block text-xs font-medium text-sr-ink">
              Archive retention override mode
            </label>
            <select
              id="policy-override-mode-select"
              name="policy[archive_retention_override_mode]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                value="inherit"
                selected={@policy_form["archive_retention_override_mode"] == "inherit"}
              >
                inherit (use deployment archive retention)
              </option>
              <option
                value="limited"
                selected={@policy_form["archive_retention_override_mode"] == "limited"}
              >
                limited (override days 1..{@plan_max_days || "3,650"})
              </option>
              <option
                :if={is_nil(@plan_max_days)}
                value="unlimited"
                selected={@policy_form["archive_retention_override_mode"] == "unlimited"}
              >
                unlimited (no time expiry)
              </option>
            </select>
          </div>

          <div>
            <label for="policy-override-days-input" class="block text-xs font-medium text-sr-ink">
              Archive retention override days (<code class="font-mono">1..{@plan_max_days || "3,650"}</code>)
            </label>
            <input
              id="policy-override-days-input"
              type="number"
              min="1"
              max={@plan_max_days || 3650}
              name="policy[archive_retention_days_override]"
              value={@policy_form["archive_retention_days_override"]}
              disabled={!@can_manage? or @policy_form["archive_retention_override_mode"] != "limited"}
              placeholder={to_string(min(30, @plan_max_days || 30))}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            />
            <p
              :if={is_integer(@plan_max_days)}
              id="policy-override-plan-limit-note"
              class="mt-1 text-xs text-sr-muted"
            >
              Maximum {@plan_max_days} days — limited by your plan.
            </p>
            <p
              :if={@policy_errors[:archive_retention_days_override]}
              id="policy-error-override-days"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:archive_retention_days_override]}
            </p>
          </div>

          <div>
            <label
              for="policy-nominal-bitrate-kbps-input"
              class="block text-xs font-medium text-sr-ink"
            >
              Simulated nominal bitrate (kbit/s, what-if preview only)
            </label>
            <input
              id="policy-nominal-bitrate-kbps-input"
              type="number"
              min="0"
              name="policy[nominal_bitrate_kbps]"
              value={@policy_form["nominal_bitrate_kbps"]}
              disabled={!@can_manage?}
              placeholder="Optional when profile unmeasured"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            />
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <label
              for="policy-visual-index-mode-select"
              class="block text-xs font-medium text-sr-ink"
            >
              Visual indexing mode
            </label>
            <p id="policy-visual-index-vantage-note" class="mt-0.5 text-[11px] text-sr-muted">
              Read by the ServiceRadar Vantage addon; has no effect without it.
            </p>
            <select
              id="policy-visual-index-mode-select"
              name="policy[visual_index_mode]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option
                value="off"
                selected={(@policy_form["visual_index_mode"] || "off") == "off"}
              >
                off
              </option>
              <option
                value="keyframes"
                selected={@policy_form["visual_index_mode"] == "keyframes"}
              >
                keyframes (sampled IDR frames)
              </option>
            </select>
            <p
              :if={@policy_errors[:visual_index_mode]}
              id="policy-error-visual-index-mode"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:visual_index_mode]}
            </p>
          </div>

          <div>
            <label
              for="policy-visual-min-interval-input"
              class="block text-xs font-medium text-sr-ink"
            >
              Min keyframe interval (ms)
            </label>
            <input
              id="policy-visual-min-interval-input"
              type="number"
              min="500"
              max="60000"
              name="policy[visual_index_min_interval_ms]"
              value={@policy_form["visual_index_min_interval_ms"] || "2000"}
              disabled={!@can_manage? or @policy_form["visual_index_mode"] != "keyframes"}
              placeholder="2000"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            />
            <p
              :if={@policy_errors[:visual_index_min_interval_ms]}
              id="policy-error-visual-min-interval"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:visual_index_min_interval_ms]}
            </p>
          </div>

          <div>
            <label
              for="policy-visual-max-frames-input"
              class="block text-xs font-medium text-sr-ink"
            >
              Max indexed frames / block
            </label>
            <input
              id="policy-visual-max-frames-input"
              type="number"
              min="1"
              max="512"
              name="policy[visual_index_max_frames_per_block]"
              value={@policy_form["visual_index_max_frames_per_block"] || "64"}
              disabled={!@can_manage? or @policy_form["visual_index_mode"] != "keyframes"}
              placeholder="64"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm font-mono text-sr-ink disabled:opacity-60"
            />
            <p
              :if={@policy_errors[:visual_index_max_frames_per_block]}
              id="policy-error-visual-max-frames"
              class="mt-1 text-xs text-rose-500"
            >
              {@policy_errors[:visual_index_max_frames_per_block]}
            </p>
          </div>
        </div>

        <p :if={@policy_errors[:base]} id="policy-error-base" class="text-xs text-rose-500">
          {@policy_errors[:base]}
        </p>

        <div :if={@can_manage?} class="flex justify-end">
          <.ui_button id="save-policy-btn" type="submit" variant="primary" size="sm">
            {if @policy_form["id"] != "", do: "Update recording policy", else: "Save recording policy"}
          </.ui_button>
        </div>
      </form>
    </section>
    """
  end

  # --- formatting helpers ----------------------------------------------------

  defp policy_camera_label(policy, sources_by_id) do
    cam_rel = fetch_val(policy, :camera_source)
    cam_id = to_string(fetch_val(policy, :camera_source_id) || "")
    src = (is_map(cam_rel) && cam_rel) || Map.get(sources_by_id, cam_id)

    if is_map(src) do
      name = fetch_val(src, :display_name) || fetch_val(src, :vendor_camera_id) || cam_id
      uid = fetch_val(src, :device_uid)
      if is_binary(uid) and uid != "", do: "#{name} (#{uid})", else: to_string(name)
    else
      cam_id
    end
  end

  defp policy_profile_label(policy) do
    prof = fetch_val(policy, :stream_profile)
    prof_id = to_string(fetch_val(policy, :stream_profile_id) || "")

    if is_map(prof) and is_binary(fetch_val(prof, :profile_name)) do
      codec = fetch_val(prof, :codec_hint) || "h264"
      "#{fetch_val(prof, :profile_name)} (#{codec})"
    else
      prof_id
    end
  end

  defp format_policy_row_estimate(policy) do
    prof = fetch_val(policy, :stream_profile) || policy
    est = CameraRecordingPolicies.profile_estimate(prof)
    format_estimate_line(est)
  end

  defp format_profile_option_label(profile, est) do
    codec = fetch_val(profile, :codec_hint) || "h264"
    "#{fetch_val(profile, :profile_name)} (#{codec}) — #{format_estimate_line(est)}"
  end

  defp format_estimate_line(%{bitrate_bps: bps, basis: basis} = est) when is_integer(bps) and bps > 0 do
    kbps = round(bps / 1_000)
    bytes_day = format_bytes(est.bytes_per_day)
    blocks_day = round(est.blocks_per_day)
    "#{kbps} kbit/s (#{basis}) · ~#{bytes_day}/day · ~#{blocks_day} blocks/day"
  end

  defp format_estimate_line(_est), do: "unknown until recorded"

  # A continuous policy says recording is wanted; a live recorder claim says it
  # is happening. Show which, rather than implying recording from the policy.
  defp policy_mode_label(policy, recording_now) do
    cond do
      not continuous_mode?(policy) -> to_string(fetch_val(policy, :mode) || :off)
      recording?(policy, recording_now) -> "continuous: recording"
      true -> "continuous: not recording yet"
    end
  end

  defp policy_mode_variant(policy, recording_now) do
    cond do
      not continuous_mode?(policy) -> "ghost"
      recording?(policy, recording_now) -> "success"
      true -> "warning"
    end
  end

  defp continuous_mode?(policy), do: fetch_val(policy, :mode) in [:continuous, "continuous"]

  defp recording?(policy, recording_now) do
    MapSet.member?(
      recording_now,
      {to_string(fetch_val(policy, :camera_source_id)), to_string(fetch_val(policy, :stream_profile_id))}
    )
  end

  defp format_override_label(policy, plan_max_days) do
    mode = fetch_val(policy, :archive_retention_override_mode) || :inherit
    days = fetch_val(policy, :archive_retention_days_override)

    case to_string(mode) do
      "limited" ->
        if is_integer(plan_max_days) and is_integer(days) and days > plan_max_days do
          "configured #{days} days, effective #{plan_max_days} days (plan maximum)"
        else
          "limited (#{days} days)"
        end

      "unlimited" ->
        if is_integer(plan_max_days) do
          "configured unlimited, effective #{plan_max_days} days (plan maximum)"
        else
          "unlimited"
        end

      _ ->
        "inherit"
    end
  end

  defp format_visual_index_summary(policy) do
    case fetch_val(policy, :visual_index_mode) do
      mode when mode in [:keyframes, "keyframes"] ->
        interval_ms = fetch_val(policy, :visual_index_min_interval_ms) || 2000
        max_frames = fetch_val(policy, :visual_index_max_frames_per_block) || 64
        "keyframes (#{interval_ms}ms · max #{max_frames})"

      _ ->
        "off"
    end
  end

  defp format_what_if_warning(:local_window_below_alert, _what_if) do
    "Projected low-water local window falls below the configured window alert threshold — local copies will recycle faster than the alert target."
  end

  defp format_what_if_warning(:sessions_exceed_limit, what_if) do
    "Projected continuous sessions on member (#{what_if.projected_sessions}) exceed the member session limit (#{what_if.max_sessions}). Assign additional cameras to another NVR member or raise SERVICERADAR_NVR_MAX_SESSIONS."
  end

  defp format_what_if_warning(:provider_throughput_exceeds_measured, what_if) do
    needed = format_rate_per_sec(what_if.provider_throughput_needed_bytes_per_sec)
    measured = format_rate_per_sec(what_if.measured_provider_throughput_bytes_per_sec || 0.0)

    "Projected provider throughput needed (#{needed}) exceeds measured provider throughput (#{measured}) — archive backlog may not drain."
  end

  defp format_what_if_warning(:block_cap_binds, what_if) do
    "Volume block cap (#{what_if.max_blocks} blocks) binds before the byte budget at ~#{format_num(what_if.projected_blocks_per_day)} blocks/day."
  end

  defp format_what_if_warning(:local_only_without_full_policy, _what_if) do
    "Local-only footage has no confirmed local_only_full_policy (behaves as stop_when_full) — blocks will be pinned and eventually stop recording on the member."
  end

  defp format_what_if_warning(:unknown_profile_bitrate, _what_if) do
    "Selected stream profile has no observed bitrate yet (unknown until recorded) — enter a simulated nominal bitrate (kbit/s) to preview its capacity impact."
  end

  defp format_what_if_warning(:object_archiving_paused, _what_if) do
    "Object-tier non-reapable bytes have reached object high water — new archive uploads are currently paused."
  end

  defp format_what_if_warning(other, _what_if), do: to_string(other)

  defp format_measured_throughput(measured_tp, measured_goodput) when is_number(measured_tp) and measured_tp > 0 do
    "Measured: #{format_rate_per_sec(measured_tp)} (goodput #{format_rate_per_sec(measured_goodput || 0.0)})"
  end

  defp format_measured_throughput(_measured_tp, _measured_goodput) do
    "Measured goodput: none in trailing 15m"
  end

  defp format_candidate_object_retention(nil, obj_proj, storage_mode) do
    if storage_mode == :local_only and Map.get(obj_proj, :policies, []) == [] do
      "Not used: local only"
    else
      case Map.get(obj_proj, :policies, []) do
        [pol | _] -> format_single_obj_policy(pol)
        _ -> "No archiving continuous policy"
      end
    end
  end

  defp format_candidate_object_retention(pol, _obj_proj, _storage_mode) do
    format_single_obj_policy(pol)
  end

  defp format_single_obj_policy(pol) do
    cfg = Map.get(pol, :configured_days)
    eff = Map.get(pol, :effective_days)
    bound = Map.get(pol, :binding_bound)

    cond do
      cfg == :unlimited and eff == :unlimited ->
        "Unlimited (configured unlimited)"

      cfg == :unlimited and is_number(eff) ->
        "~#{format_num(eff)} days (configured unlimited, capacity binds)"

      is_number(cfg) and bound == :time ->
        "~#{format_num(eff)} days (configured #{cfg}d, time binds)"

      is_number(cfg) and is_number(eff) ->
        "~#{format_num(eff)} days (configured #{cfg}d, capacity binds)"

      true ->
        "Unlimited"
    end
  end

  defp format_local_window_summary(local_proj) do
    status = Map.get(local_proj, :status, :not_recording)
    low = Map.get(local_proj, :window_low_seconds, 0.0)
    high = Map.get(local_proj, :window_high_seconds, 0.0)
    bound = Map.get(local_proj, :binding_bound, :budget)

    cond do
      status == :not_recording ->
        "Not recording on target member"

      low == :until_policy_or_age_changes ->
        "Pinned under stop_when_full (kept until policy or max age changes)"

      low == :infinity ->
        "Unlimited at current rate"

      is_number(low) and is_number(high) ->
        est_note = if status == :estimated, do: ", estimated", else: ""
        "~#{format_window_range(low, high)} (#{format_bound_text(bound)}#{est_note})"

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
  defp format_bound_text(:pinned), do: "pinned"
  defp format_bound_text(_), do: "budget binds"

  defp format_local_bound_badge(:not_recording), do: "Idle"
  defp format_local_bound_badge(:max_age), do: "Age ceiling"
  defp format_local_bound_badge(:block_cap), do: "Block cap"
  defp format_local_bound_badge(:pinned), do: "Pinned"
  defp format_local_bound_badge(_), do: "Budget"

  defp format_time_to_full(:not_filling), do: "not filling"
  defp format_time_to_full(sec) when is_number(sec), do: "about #{format_span(sec)}"
  defp format_time_to_full(_), do: "not filling"

  defp format_days_to_capacity(:not_filling), do: "not filling"
  defp format_days_to_capacity(days) when is_number(days), do: "about #{format_num(days)} days"
  defp format_days_to_capacity(_), do: "not filling"

  defp format_rate_per_sec(bytes_per_sec) when is_number(bytes_per_sec) and bytes_per_sec > 0 do
    "#{format_bytes(bytes_per_sec)}/s"
  end

  defp format_rate_per_sec(_), do: "0 B/s"

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

  @member_name_pattern ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  defp build_member_options(runtime, policies, policy_form) do
    runtime_list =
      runtime
      |> Map.get(:core_elx, %{})
      |> Map.get(:members, [])

    by_member =
      Enum.reduce(runtime_list, %{}, fn m, acc ->
        name = m |> fetch_val(:member) |> trimmed_str()
        sid = m |> fetch_val(:storage_id) |> trimmed_str()

        if name == "" do
          acc
        else
          label =
            if sid == "" do
              name
            else
              "#{name} (#{String.slice(sid, 0, 8)}...)"
            end

          Map.put_new(acc, name, %{value: name, label: label})
        end
      end)

    by_member =
      Enum.reduce(policies, by_member, fn pol, acc ->
        name = pol |> fetch_val(:nvr_member) |> trimmed_str()

        if name != "" and not Map.has_key?(acc, name) do
          Map.put(acc, name, %{value: name, label: name})
        else
          acc
        end
      end)

    current_member = policy_form |> Map.get("nvr_member") |> trimmed_str()

    by_member =
      if current_member != "" and Regex.match?(@member_name_pattern, current_member) and
           not Map.has_key?(by_member, current_member) do
        Map.put(by_member, current_member, %{value: current_member, label: current_member})
      else
        by_member
      end

    by_member
    |> Map.values()
    |> Enum.sort_by(& &1.value)
  end

  defp unmeasured_active_what_if?(what_if, warnings) when is_map(what_if) do
    sessions = Map.get(what_if, :projected_sessions) || 0

    total_capture_bps =
      (Map.get(what_if, :archive_capture_rate_bytes_per_sec) || 0) +
        (Map.get(what_if, :local_only_capture_rate_bytes_per_sec) || 0) +
        (Map.get(what_if, :projected_capture_bytes_per_sec) || 0)

    unknown_bitrate? =
      :unknown_profile_bitrate in warnings or
        Map.get(what_if, :unknown_bitrate_policy_ids, []) != []

    sessions > 0 and total_capture_bps <= 0 and unknown_bitrate?
  end

  defp trimmed_str(nil), do: ""
  defp trimmed_str(val), do: val |> to_string() |> String.trim()
end
