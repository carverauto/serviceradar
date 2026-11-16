defmodule ServiceRadarWebNGWeb.Settings.RecordingLive.Components do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  @tabs [
    %{id: "recorders", label: "Recorders", stage_b?: false},
    %{id: "archive", label: "Archive", stage_b?: false},
    %{id: "cameras", label: "Cameras", stage_b?: false},
    %{id: "policy", label: "Policy", stage_b?: true},
    %{id: "retention", label: "Retention", stage_b?: false},
    %{id: "health", label: "Health", stage_b?: true}
  ]

  attr :runtime, :map, required: true
  attr :can_view_any?, :boolean, default: true

  def install_and_gate_banner(assigns) do
    ~H"""
    <section
      id="recording-runtime-banner"
      aria-label="Recording installation and recovery gate status"
      class="rounded-xl border border-sr-line bg-sr-subtle/40 p-4 space-y-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-semibold text-sr-ink">
            Installation &amp; Deployment Recovery Gate
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Source: Core NVR reservations and verified archive receipts (distinct from the
            <code class="font-mono">ArchiveUploads</code>
            published catalog on camera recordings pages).
          </p>
        </div>
        <.ui_button
          id="refresh-recording-runtime"
          type="button"
          phx-click="refresh_status"
          variant="outline"
          size="xs"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh status
        </.ui_button>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div
          id="recording-status-nvr-install"
          class="rounded-lg border border-sr-line bg-sr-surface p-3"
        >
          <div class="text-xs text-sr-muted">NVR client installation</div>
          <div class="mt-1 flex items-center gap-2">
            <.ui_badge
              size="xs"
              variant={nvr_install_badge_variant(@runtime.core_elx.nvr_installation)}
            >
              {nvr_install_label(@runtime.core_elx.nvr_installation)}
            </.ui_badge>
          </div>
        </div>

        <div
          id="recording-status-core-gate"
          class="rounded-lg border border-sr-line bg-sr-surface p-3"
        >
          <div class="text-xs text-sr-muted">Core recovery gate</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <.ui_badge size="xs" variant={gate_badge_variant(@runtime.recovery_gate.state)}>
              {gate_label(@runtime.recovery_gate.state)}
            </.ui_badge>
            <span
              :if={@runtime.recovery_gate.generation}
              class="font-mono text-[11px] text-sr-muted"
            >
              {String.slice(@runtime.recovery_gate.generation, 0, 8)}
            </span>
          </div>
        </div>

        <div
          id="recording-status-core-elx"
          class="rounded-lg border border-sr-line bg-sr-surface p-3"
        >
          <div class="text-xs text-sr-muted">core-elx reachability</div>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <.ui_badge size="xs" variant={reachability_badge_variant(@runtime.core_elx.reachability)}>
              {reachability_label(@runtime.core_elx.reachability)}
            </.ui_badge>
            <span :if={@runtime.core_elx.node} class="font-mono text-[11px] text-sr-muted">
              {@runtime.core_elx.node}
            </span>
          </div>
        </div>

        <div
          id="recording-status-supervisor"
          class="rounded-lg border border-sr-line bg-sr-surface p-3"
        >
          <div class="text-xs text-sr-muted">Capture supervisor</div>
          <div class="mt-1 flex items-center gap-2">
            <.ui_badge size="xs" variant={supervisor_badge_variant(@runtime.core_elx.supervisor)}>
              {supervisor_label(@runtime.core_elx.supervisor)}
            </.ui_badge>
          </div>
        </div>
      </div>

      <p id="recording-gate-guidance" class="text-xs text-sr-muted">
        The Settings UI reports the deployment recovery gate and never opens or closes it. Follow the
        deployment recovery gate procedure in <code class="font-mono">docs/nvr-runtime.md</code>.
      </p>
    </section>
    """
  end

  attr :active_tab, :string, required: true

  def tab_bar(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <nav
      id="recording-settings-tabs"
      aria-label="Recording settings sections"
      class="flex flex-wrap items-center gap-2 border-b border-sr-line pb-2"
    >
      <.link
        :for={tab <- @tabs}
        id={"recording-tab-#{tab.id}"}
        patch={~p"/settings/recording?#{%{tab: tab.id}}"}
        aria-current={if(@active_tab == tab.id, do: "page", else: nil)}
        class={[
          "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
          if(@active_tab == tab.id,
            do: "bg-sr-brand/10 text-sr-ink border border-sr-brand/40",
            else: "text-sr-muted hover:bg-sr-subtle hover:text-sr-ink border border-transparent"
          )
        ]}
      >
        <span>{tab.label}</span>
        <.ui_badge :if={tab.stage_b?} size="xs" variant="ghost">Blocked</.ui_badge>
      </.link>
    </nav>
    """
  end

  attr :runtime, :map, required: true
  attr :storage_mode, :atom, default: :local_only
  attr :members, :list, default: []

  def recorders_panel(assigns) do
    ~H"""
    <div id="recording-tab-panel-recorders" class="space-y-4">
      <section
        :if={@runtime.core_elx.nvr_installation == :not_installed}
        id="recording-not-installed-panel"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-2"
      >
        <div class="flex items-center gap-2">
          <.icon name="hero-information-circle" class="size-5 text-sr-muted" />
          <h2 class="text-base font-semibold text-sr-ink">NVR is not installed</h2>
        </div>
        <p class="text-sm text-sr-muted">
          <code class="font-mono">core-elx</code>
          reports that no NVR client configuration is installed for this deployment. Recorder member,
          destination, and block lists are hidden rather than shown as empty.
        </p>
        <p class="text-xs text-sr-muted">
          Installation and deployment recovery gate reference: <code class="font-mono">docs/nvr-runtime.md</code>.
        </p>
      </section>

      <section
        :if={
          @runtime.core_elx.reachability == :unreachable or
            @runtime.core_elx.nvr_installation == :unknown
        }
        id="recording-recorders-unknown-panel"
        class="rounded-xl border border-amber-500/40 bg-amber-500/5 p-5 space-y-2"
      >
        <div class="flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-5 text-amber-500" />
          <h2 class="text-base font-semibold text-sr-ink">Recorder state unknown</h2>
        </div>
        <p class="text-sm text-sr-muted">
          <code class="font-mono">core-elx</code>
          did not respond within the bounded RPC deadline (or runtime status has not loaded yet).
          Recorder installation, member readiness, member recovery gate, and spool capacity are
          reported as <strong>unknown</strong>, never as absent or empty.
        </p>
      </section>

      <section
        :if={@runtime.core_elx.nvr_installation in [:installed, :invalid_config]}
        id="recording-recorders-status-panel"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">Recorder Runtime &amp; Spool Policy</h2>
            <p class="mt-1 text-sm text-sr-muted">
              Per-member readiness, member recovery gate state, and spool capacity are reported as
              <strong>unknown</strong>
              until the NVR member status endpoint answers; unreachable or unexposed members are never
              rendered as an empty recorder list.
            </p>
          </div>
          <.ui_badge
            id="recorders-storage-mode-badge"
            size="xs"
            variant={if(@storage_mode == :local_and_archive, do: "success", else: "ghost")}
          >
            {if @storage_mode == :local_and_archive,
              do: "Local + archive",
              else: "Local only: no object storage configured"}
          </.ui_badge>
        </div>

        <div
          :if={@runtime.recovery_gate.state in [:closed, :not_configured]}
          id="recording-gate-closed-callout"
          class="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-xs text-sr-ink space-y-1"
        >
          <p class="font-semibold">
            {if @runtime.recovery_gate.state == :not_configured,
              do: "Core deployment recovery gate is not configured.",
              else: "Core deployment recovery gate is closed."}
          </p>
          <p class="text-sr-muted">
            Recording admission remains blocked until deployment control provides a valid ready state
            file outside the restored media volume. See
            <code class="font-mono">docs/nvr-runtime.md</code>
            ("Deployment recovery gate"); no UI control can open or close this gate.
          </p>
        </div>

        <div
          id="recording-member-budgets-section"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3 space-y-1.5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-xs font-semibold text-sr-ink">
              Per-Member Local Byte Budget &amp; Reserve
            </h3>
            <.ui_badge size="xs" variant="ghost">Desired vs applied</.ui_badge>
          </div>
          <p :if={@members == []} class="text-xs text-sr-muted">
            Per-member local byte budget (<code class="font-mono">budget_bytes</code>), free-space
            reserve (<code class="font-mono">reserve_bytes</code>), install ceiling
            (<code class="font-mono">nvr.maxSpoolBytes</code>) and floor
            (<code class="font-mono">nvr.reserveBytes</code>), volume capacity, and effective local
            window are reported as <strong>unknown</strong>
            until the NVR member <code class="font-mono">GET /v1/status</code>
            endpoint answers, and remain read-only
            install values until runtime <code class="font-mono">NVRStorageSettings</code>
            synchronization lands.
          </p>
        </div>

        <div
          id="recording-local-retention-notice"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3 text-xs text-sr-muted"
        >
          <strong class="text-sr-ink">Local retention and capacity eviction are not yet enforced:</strong>
          local blocks are not reclaimed by byte budget or maximum local age, and new bounded captures
          are refused when recorder spool capacity is exhausted.
        </div>
      </section>
    </div>
    """
  end

  attr :runtime, :map, required: true
  attr :storage_mode, :atom, default: :local_only
  attr :bindings, :list, required: true
  attr :credentials, :list, required: true
  attr :can_manage?, :boolean, required: true
  attr :can_manage_credentials?, :boolean, required: true
  attr :settings_form, :map, required: true
  attr :destination_form, :map, required: true
  attr :destination_errors, :map, required: true
  attr :selected_writer_label, :string, required: true
  attr :selected_reader_label, :string, required: true
  attr :selected_retention_label, :string, default: "None selected (object retention not enforced)"
  attr :object_retention_enforced?, :boolean, default: false
  attr :credential_issue, :string, default: nil
  attr :active_binding_id, :string, default: nil

  def archive_panel(assigns) do
    ~H"""
    <div id="recording-tab-panel-archive" class="space-y-6">
      <div
        :if={@credential_issue}
        id="archive-credential-unavailable-banner"
        role="alert"
        class="rounded-xl border border-rose-500/40 bg-rose-500/10 p-4 text-sm text-sr-ink"
      >
        <p class="font-semibold">Archive unavailable due to credential state</p>
        <p class="mt-1 text-xs text-sr-muted">{@credential_issue}</p>
      </div>

      <section
        :if={
          @runtime.core_elx.nvr_installation != :not_installed and
            @storage_mode == :local_only
        }
        id="archive-local-only-banner"
        class="rounded-xl border border-sr-line bg-sr-subtle/40 p-4 space-y-1.5"
      >
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge id="archive-mode-badge" size="xs" variant="ghost">Local only</.ui_badge>
          <p id="archive-local-only-heading" class="text-sm font-semibold text-sr-ink">
            Local only: no object storage configured
          </p>
        </div>
        <p class="text-xs text-sr-muted">
          Local-only recording is a complete operating mode on NVR storage with no S3 bucket or
          archive credentials required. Register and select an S3-compatible destination below and
          enable archive operations only when you want sealed blocks copied to object storage.
        </p>
      </section>

      <section
        :if={@runtime.core_elx.nvr_installation == :not_installed}
        id="archive-not-installed-notice"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-2"
      >
        <h2 class="text-base font-semibold text-sr-ink">NVR is not installed</h2>
        <p class="text-sm text-sr-muted">
          No NVR client configuration is installed on <code class="font-mono">core-elx</code>. See
          <code class="font-mono">docs/nvr-runtime.md</code>
          for installation instructions.
        </p>
      </section>

      <.archive_settings_card
        bindings={@bindings}
        credentials={@credentials}
        can_manage?={@can_manage?}
        can_manage_credentials?={@can_manage_credentials?}
        settings_form={@settings_form}
        selected_writer_label={@selected_writer_label}
        selected_reader_label={@selected_reader_label}
        selected_retention_label={@selected_retention_label}
        object_retention_enforced?={@object_retention_enforced?}
        active_binding_id={@active_binding_id}
      />

      <.credentials_inventory_card
        credentials={@credentials}
        can_manage?={@can_manage?}
        can_manage_credentials?={@can_manage_credentials?}
        selected_writer_label={@selected_writer_label}
        selected_reader_label={@selected_reader_label}
      />

      <.destination_registration_card
        :if={@can_manage?}
        destination_form={@destination_form}
        destination_errors={@destination_errors}
      />

      <.archive_bindings_card
        :if={@runtime.core_elx.nvr_installation != :not_installed or @bindings != []}
        bindings={@bindings}
        active_binding_id={@active_binding_id}
      />
    </div>
    """
  end

  attr :bindings, :list, required: true
  attr :credentials, :list, required: true
  attr :can_manage?, :boolean, required: true
  attr :can_manage_credentials?, :boolean, required: true
  attr :settings_form, :map, required: true
  attr :selected_writer_label, :string, required: true
  attr :selected_reader_label, :string, required: true
  attr :selected_retention_label, :string, required: true
  attr :object_retention_enforced?, :boolean, default: false
  attr :active_binding_id, :string, default: nil

  defp archive_settings_card(assigns) do
    retention_unselected? =
      if assigns.can_manage? and assigns.can_manage_credentials? do
        assigns.settings_form["retention_credential_secret_id"] in [nil, ""]
      else
        not assigns.object_retention_enforced?
      end

    assigns =
      assigns
      |> assign(:show_unenforced_notice?, assigns.settings_form["archive_enabled"] == "true" and retention_unselected?)
      |> assign(
        :show_awaiting_binding_warning?,
        assigns.settings_form["archive_enabled"] == "true" and
          assigns.settings_form["active_archive_binding_id"] in [nil, ""]
      )

    ~H"""
    <section
      id="recording-archive-settings-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Active Archive Configuration</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Run in local-only mode with no bucket, or select an immutable destination generation,
            enable archive operations, and bind reusable <code class="font-mono">s3_compatible</code>
            credentials by identifier. Secret key material is never entered or displayed here.
          </p>
        </div>
        <.link
          id="archive-credentials-settings-link"
          navigate={~p"/settings/networks/credentials"}
          class="sr-ops-button text-xs"
        >
          Manage credentials
        </.link>
      </div>

      <form
        id="recording-archive-settings-form"
        phx-change="validate_archive_settings"
        phx-submit="save_archive_settings"
        class="space-y-4"
      >
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label for="active-archive-binding-select" class="block text-xs font-medium text-sr-ink">
              Active destination generation
            </label>
            <select
              id="active-archive-binding-select"
              name="settings[active_archive_binding_id]"
              disabled={!@can_manage?}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option value="" selected={@settings_form["active_archive_binding_id"] in [nil, ""]}>
                None (local-only mode)
              </option>
              <option
                :for={binding <- @bindings}
                value={binding.id}
                selected={@settings_form["active_archive_binding_id"] == to_string(binding.id)}
              >
                {binding.provisioning_ref} (gen {binding.generation}) — {binding.bucket}/{binding.namespace}
              </option>
            </select>
          </div>

          <div class="flex items-end">
            <label class="inline-flex items-center gap-2 text-sm text-sr-ink">
              <input type="hidden" name="settings[archive_enabled]" value="false" />
              <input
                id="archive-enabled-checkbox"
                type="checkbox"
                name="settings[archive_enabled]"
                value="true"
                checked={@settings_form["archive_enabled"] == "true"}
                disabled={!@can_manage?}
                class="rounded border-sr-line"
              />
              <span>Enable archive operations</span>
            </label>
          </div>
        </div>

        <div
          :if={@show_awaiting_binding_warning?}
          id="archive-awaiting-binding-warning"
          class="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-xs text-sr-ink"
        >
          Enabling archive requires an active destination generation; ending or clearing the active
          binding while archive is enabled leaves new footage owed a copy waiting in <code class="font-mono">awaiting_binding</code>.
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <label for="writer-credential-select" class="block text-xs font-medium text-sr-ink">
              Writer credential (<code class="font-mono">s3_compatible</code>)
            </label>
            <select
              :if={@can_manage? and @can_manage_credentials?}
              id="writer-credential-select"
              name="settings[writer_credential_secret_id]"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            >
              <option value="" selected={@settings_form["writer_credential_secret_id"] in [nil, ""]}>
                None selected
              </option>
              <option
                :for={cred <- @credentials}
                value={cred.id}
                selected={@settings_form["writer_credential_secret_id"] == to_string(cred.id)}
              >
                {cred.name}
              </option>
            </select>
            <select
              :if={!(@can_manage? and @can_manage_credentials?)}
              id="writer-credential-disabled-select"
              disabled
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-muted opacity-70"
            >
              <option selected>{@selected_writer_label}</option>
            </select>
          </div>

          <div>
            <label for="reader-credential-select" class="block text-xs font-medium text-sr-ink">
              Optional reader credential (defaults to writer in reader role)
            </label>
            <select
              :if={@can_manage? and @can_manage_credentials?}
              id="reader-credential-select"
              name="settings[reader_credential_secret_id]"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            >
              <option value="" selected={@settings_form["reader_credential_secret_id"] in [nil, ""]}>
                Use writer credential (reader role)
              </option>
              <option
                :for={cred <- @credentials}
                value={cred.id}
                selected={@settings_form["reader_credential_secret_id"] == to_string(cred.id)}
              >
                {cred.name}
              </option>
            </select>
            <select
              :if={!(@can_manage? and @can_manage_credentials?)}
              id="reader-credential-disabled-select"
              disabled
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-muted opacity-70"
            >
              <option selected>{@selected_reader_label}</option>
            </select>
          </div>

          <div>
            <label for="retention-credential-select" class="block text-xs font-medium text-sr-ink">
              Optional retention delete credential (<code class="font-mono">DELETE</code>, <code class="font-mono">HEAD</code>)
            </label>
            <select
              :if={@can_manage? and @can_manage_credentials?}
              id="retention-credential-select"
              name="settings[retention_credential_secret_id]"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            >
              <option
                value=""
                selected={@settings_form["retention_credential_secret_id"] in [nil, ""]}
              >
                None selected (object retention not enforced)
              </option>
              <option
                :for={cred <- @credentials}
                value={cred.id}
                selected={@settings_form["retention_credential_secret_id"] == to_string(cred.id)}
              >
                {cred.name}
              </option>
            </select>
            <select
              :if={!(@can_manage? and @can_manage_credentials?)}
              id="retention-credential-disabled-select"
              disabled
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-muted opacity-70"
            >
              <option selected>{@selected_retention_label}</option>
            </select>
          </div>
        </div>

        <p
          :if={@show_unenforced_notice?}
          id="archive-retention-unenforced-notice"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 px-3 py-2 text-xs text-sr-ink"
        >
          <strong>Object retention not enforced: no delete credential</strong>
          — archive uploads proceed, and ServiceRadar will not delete expired or capacity-reaped
          objects until a retention credential is bound.
        </p>

        <p
          :if={@can_manage? and !@can_manage_credentials?}
          id="archive-missing-credentials-permission-note"
          class="text-xs text-amber-500"
        >
          Changing archive credentials additionally requires <code class="font-mono">settings.credentials.manage</code>. Currently bound credentials are
          shown above as redacted names and preserved when saving other archive settings.
        </p>

        <div :if={@can_manage?} class="flex justify-end">
          <.ui_button id="save-archive-settings-btn" type="submit" variant="primary" size="sm">
            Save archive settings
          </.ui_button>
        </div>
      </form>
    </section>
    """
  end

  attr :credentials, :list, required: true
  attr :can_manage?, :boolean, required: true
  attr :can_manage_credentials?, :boolean, required: true
  attr :selected_writer_label, :string, required: true
  attr :selected_reader_label, :string, required: true

  defp credentials_inventory_card(assigns) do
    ~H"""
    <section
      id="archive-credentials-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Available <code class="font-mono">s3_compatible</code> Credentials
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Bucket access keys live exclusively in <code class="font-mono">platform.network_credential_secrets</code>. Create or rotate them
            in the Credentials inventory.
          </p>
        </div>
        <.link
          id="archive-credentials-inventory-link"
          navigate={~p"/settings/networks/credentials"}
          class="sr-ops-button text-xs"
        >
          Create or manage in Credentials
        </.link>
      </div>

      <p
        :if={!@can_manage_credentials?}
        id="archive-credentials-redacted-note"
        class="text-xs text-sr-muted"
      >
        Listing reusable <code class="font-mono">s3_compatible</code>
        credentials requires <code class="font-mono">settings.credentials.manage</code>.
      </p>

      <p
        :if={@can_manage_credentials? and @credentials == []}
        id="archive-credentials-empty"
        class="text-xs text-sr-muted"
      >
        No enabled <code class="font-mono">s3_compatible</code>
        credentials exist. Credentials are not
        required in local-only mode; create one in
        <.link
          navigate={~p"/settings/networks/credentials"}
          class="underline"
        >
          Credentials settings
        </.link>
        only when enabling object-storage archiving.
      </p>

      <ul
        :if={@can_manage_credentials? and @credentials != []}
        id="archive-credentials-list"
        class="divide-y divide-sr-line rounded-lg border border-sr-line"
      >
        <li
          :for={cred <- @credentials}
          id={"archive-credential-#{cred.id}"}
          class="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm"
        >
          <div>
            <span class="font-medium text-sr-ink">{cred.name}</span>
            <span :if={cred.description} class="ml-2 text-xs text-sr-muted">
              {cred.description}
            </span>
          </div>
          <.ui_badge size="xs" variant="success">Enabled</.ui_badge>
        </li>
      </ul>
    </section>
    """
  end

  attr :destination_form, :map, required: true
  attr :destination_errors, :map, required: true

  defp destination_registration_card(assigns) do
    ~H"""
    <section
      id="register-archive-destination-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div>
        <h2 class="text-base font-semibold text-sr-ink">
          Register Immutable Destination Generation
        </h2>
        <p class="mt-1 text-xs text-sr-muted">
          Registers a new <code class="font-mono">operator:&lt;name&gt;</code> archive binding
          generation. Existing generations and receipts bound to them remain immutable.
        </p>
      </div>

      <form
        id="register-archive-destination-form"
        phx-change="validate_destination"
        phx-submit="register_destination"
        class="space-y-4"
      >
        <div class="grid gap-4 md:grid-cols-2">
          <div>
            <label for="destination-name-input" class="block text-xs font-medium text-sr-ink">
              Destination name (<code class="font-mono">operator:&lt;name&gt;</code>)
            </label>
            <input
              id="destination-name-input"
              type="text"
              name="destination[name]"
              value={@destination_form["name"]}
              placeholder="primary"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            />
            <p
              :if={@destination_errors[:name]}
              id="destination-error-name"
              class="mt-1 text-xs text-rose-500"
            >
              {@destination_errors[:name]}
            </p>
          </div>

          <div>
            <label for="destination-endpoint-input" class="block text-xs font-medium text-sr-ink">
              HTTPS endpoint (port 443 DNS host, no IP literal or path)
            </label>
            <input
              id="destination-endpoint-input"
              type="text"
              name="destination[endpoint]"
              value={@destination_form["endpoint"]}
              placeholder="https://objects.example.com"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            />
            <p
              :if={@destination_errors[:endpoint]}
              id="destination-error-endpoint"
              class="mt-1 text-xs text-rose-500"
            >
              {@destination_errors[:endpoint]}
            </p>
          </div>

          <div>
            <label for="destination-region-input" class="block text-xs font-medium text-sr-ink">
              Region
            </label>
            <input
              id="destination-region-input"
              type="text"
              name="destination[region]"
              value={@destination_form["region"]}
              placeholder="example-1"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            />
            <p
              :if={@destination_errors[:region]}
              id="destination-error-region"
              class="mt-1 text-xs text-rose-500"
            >
              {@destination_errors[:region]}
            </p>
          </div>

          <div>
            <label for="destination-bucket-input" class="block text-xs font-medium text-sr-ink">
              Bucket
            </label>
            <input
              id="destination-bucket-input"
              type="text"
              name="destination[bucket]"
              value={@destination_form["bucket"]}
              placeholder="example-archive"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            />
            <p
              :if={@destination_errors[:bucket]}
              id="destination-error-bucket"
              class="mt-1 text-xs text-rose-500"
            >
              {@destination_errors[:bucket]}
            </p>
          </div>

          <div class="md:col-span-2">
            <label for="destination-namespace-input" class="block text-xs font-medium text-sr-ink">
              Key prefix (<code class="font-mono">namespace</code>)
            </label>
            <input
              id="destination-namespace-input"
              type="text"
              name="destination[namespace]"
              value={@destination_form["namespace"]}
              placeholder="recordings/v1"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            />
            <p
              :if={@destination_errors[:namespace]}
              id="destination-error-namespace"
              class="mt-1 text-xs text-rose-500"
            >
              {@destination_errors[:namespace]}
            </p>
          </div>
        </div>

        <p
          :if={@destination_errors[:base]}
          id="destination-error-base"
          class="text-xs text-rose-500"
        >
          {@destination_errors[:base]}
        </p>

        <div class="flex justify-end">
          <.ui_button id="register-destination-submit" type="submit" variant="primary" size="sm">
            Register destination generation
          </.ui_button>
        </div>
      </form>
    </section>
    """
  end

  attr :bindings, :list, required: true
  attr :active_binding_id, :string, default: nil

  defp archive_bindings_card(assigns) do
    ~H"""
    <section
      id="archive-bindings-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div>
        <h2 class="text-base font-semibold text-sr-ink">Archive Destination Generations</h2>
        <p class="mt-1 text-xs text-sr-muted">
          Destinations are immutable <code class="font-mono">ArchiveBinding</code> generations. Every
          destination remains <strong>unqualified</strong>; connectivity tests verify reachability only
          and never qualify a storage provider.
        </p>
      </div>

      <p
        :if={@bindings == []}
        id="archive-bindings-empty"
        class="text-sm text-sr-muted"
      >
        No archive destination generations registered. Local-only recording requires no object-storage
        destination.
      </p>

      <div :if={@bindings != []} class="overflow-x-auto">
        <table id="archive-destinations-list" class="w-full text-left text-xs">
          <thead class="border-b border-sr-line text-sr-muted">
            <tr>
              <th class="py-2 pr-3 font-medium">Reference &amp; Gen</th>
              <th class="py-2 pr-3 font-medium">Endpoint</th>
              <th class="py-2 pr-3 font-medium">Region</th>
              <th class="py-2 pr-3 font-medium">Bucket &amp; Key Prefix</th>
              <th class="py-2 pr-3 font-medium">Destination SHA-256</th>
              <th class="py-2 font-medium">Capability State</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-sr-line">
            <tr
              :for={binding <- @bindings}
              id={"archive-binding-#{binding.id}"}
              class="align-top"
            >
              <td class="py-2.5 pr-3 font-mono text-sr-ink">
                <div>{binding.provisioning_ref}</div>
                <div class="mt-0.5 flex items-center gap-1.5 text-[11px] text-sr-muted">
                  <span>gen {binding.generation}</span>
                  <.ui_badge
                    :if={@active_binding_id == to_string(binding.id)}
                    size="xs"
                    variant="success"
                  >
                    Active
                  </.ui_badge>
                </div>
              </td>
              <td class="py-2.5 pr-3 font-mono text-sr-ink">{binding.endpoint}</td>
              <td class="py-2.5 pr-3 font-mono text-sr-ink">{binding.region}</td>
              <td class="py-2.5 pr-3 font-mono text-sr-ink">
                {binding.bucket}/{binding.namespace}
              </td>
              <td class="py-2.5 pr-3 font-mono text-[11px] text-sr-muted">
                {binding.destination_sha256}
              </td>
              <td class="py-2.5">
                <.ui_badge size="xs" variant="ghost">unqualified</.ui_badge>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :runtime, :map, required: true
  attr :sources, :list, required: true
  attr :profiles, :list, required: true
  attr :sources_forbidden?, :boolean, required: true
  attr :selected_camera_id, :string, default: nil
  attr :selected_profile_id, :string, default: nil
  attr :blocks_loaded?, :boolean, required: true
  attr :blocks_empty?, :boolean, required: true
  attr :blocks_filtered_more?, :boolean, default: false
  attr :blocks_next_cursor, :any, default: nil
  attr :streams, :map, required: true
  attr :timezone, :string, required: true

  def cameras_panel(assigns) do
    ~H"""
    <div id="recording-tab-panel-cameras" class="space-y-6">
      <section
        :if={@runtime.core_elx.nvr_installation == :not_installed}
        id="cameras-not-installed-notice"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-2"
      >
        <h2 class="text-base font-semibold text-sr-ink">NVR is not installed</h2>
        <p class="text-sm text-sr-muted">
          No NVR client configuration is installed on <code class="font-mono">core-elx</code>. Block
          lists are hidden rather than rendered as empty. See <code class="font-mono">docs/nvr-runtime.md</code>.
        </p>
      </section>

      <section
        :if={@runtime.core_elx.nvr_installation != :not_installed}
        id="recording-camera-picker-card"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
      >
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Camera &amp; Stream Profile Selection</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Select a camera source and relay-eligible stream profile to inspect Core NVR block
            reservations and verified archive receipts.
          </p>
        </div>

        <p
          :if={@sources_forbidden?}
          id="recording-cameras-devices-permission-note"
          class="text-xs text-amber-500"
        >
          Listing camera sources and stream profiles additionally requires <code class="font-mono">devices.view</code>.
        </p>

        <form
          :if={!@sources_forbidden?}
          id="recording-camera-picker-form"
          phx-change="select_camera_context"
          class="grid gap-4 md:grid-cols-2"
        >
          <div>
            <label for="recording-camera-select" class="block text-xs font-medium text-sr-ink">
              Camera source
            </label>
            <select
              id="recording-camera-select"
              name="camera_source_id"
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink"
            >
              <option value="" selected={@selected_camera_id in [nil, ""]}>
                Select a camera
              </option>
              <option
                :for={source <- @sources}
                value={source.id}
                selected={@selected_camera_id == to_string(source.id)}
              >
                {source.display_name || source.vendor_camera_id} ({source.device_uid})
              </option>
            </select>
          </div>

          <div>
            <label for="recording-profile-select" class="block text-xs font-medium text-sr-ink">
              Relay-eligible stream profile
            </label>
            <select
              id="recording-profile-select"
              name="stream_profile_id"
              disabled={@selected_camera_id in [nil, ""]}
              class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
            >
              <option value="" selected={@selected_profile_id in [nil, ""]}>
                All relay-eligible profiles ({length(@profiles)})
              </option>
              <option
                :for={profile <- @profiles}
                value={profile.id}
                selected={@selected_profile_id == to_string(profile.id)}
              >
                {profile.profile_name} ({profile.codec_hint || "codec unspecified"})
              </option>
            </select>
          </div>
        </form>
      </section>

      <section
        :if={
          @runtime.core_elx.nvr_installation != :not_installed and
            @selected_camera_id not in [nil, ""]
        }
        id="camera-recording-blocks-section"
        class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">Per-Camera Block Locations</h2>
            <p class="mt-1 text-xs text-sr-muted">
              Core <code class="font-mono">open_local</code> rows represent Core block reservations,
              not local NVR seal state. When the owning NVR member lookup is unavailable or
              unreachable, local copy state is shown as <strong>unknown</strong> (never absent).
            </p>
          </div>
        </div>

        <p
          :if={@blocks_loaded? and @blocks_empty?}
          id="camera-recording-blocks-empty"
          class="text-sm text-sr-muted"
        >
          No NVR block reservations recorded in Core for this camera.
        </p>

        <p
          :if={@blocks_loaded? and @blocks_filtered_more?}
          id="camera-recording-blocks-filtered-more"
          class="text-sm text-sr-muted"
        >
          No blocks in the current page match the selected stream profile. Load older blocks to
          check earlier reservations.
        </p>

        <div class="overflow-x-auto">
          <table class="w-full text-left text-xs">
            <thead class="border-b border-sr-line text-sr-muted">
              <tr>
                <th class="py-2 pr-3 font-medium">Block Key</th>
                <th class="py-2 pr-3 font-medium">Storage ID</th>
                <th class="py-2 pr-3 font-medium">Core Record</th>
                <th class="py-2 pr-3 font-medium">Local Copy (NVR)</th>
                <th class="py-2 pr-3 font-medium">Archive Copy (Core Receipt)</th>
                <th class="py-2 font-medium">Reserved At</th>
              </tr>
            </thead>
            <tbody
              id="camera-recording-blocks-stream"
              phx-update="stream"
              class="divide-y divide-sr-line"
            >
              <tr :for={{dom_id, row} <- @streams.recording_blocks} id={dom_id} class="align-top">
                <td class="py-2.5 pr-3 font-mono text-sr-ink">{row.block_key}</td>
                <td class="py-2.5 pr-3 font-mono text-[11px] text-sr-muted">{row.storage_id}</td>
                <td class="py-2.5 pr-3">
                  <.ui_badge size="xs" variant="ghost">{row.core_state_label}</.ui_badge>
                </td>
                <td class="py-2.5 pr-3">
                  <.ui_badge size="xs" variant="warning">{row.local_copy_label}</.ui_badge>
                </td>
                <td class="py-2.5 pr-3">
                  <div class="space-y-1">
                    <.ui_badge
                      size="xs"
                      variant={if(row.receipt, do: "success", else: "ghost")}
                    >
                      {row.archive_copy_label}
                    </.ui_badge>
                    <div :if={row.receipt} class="text-[11px] text-sr-muted space-y-0.5">
                      <div :for={obj <- row.receipt_objects} class="font-mono">
                        {format_receipt_object(obj)}
                      </div>
                    </div>
                  </div>
                </td>
                <td class="py-2.5 text-sr-muted">
                  <.user_time
                    :if={row.inserted_at}
                    id={"block-inserted-#{row.id}"}
                    value={row.inserted_at}
                    timezone={@timezone}
                    style={:compact}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@blocks_next_cursor} class="flex justify-end">
          <.ui_button
            id="next-camera-blocks-page"
            type="button"
            phx-click="next_blocks_page"
            variant="outline"
            size="xs"
          >
            Load older blocks
          </.ui_button>
        </div>
      </section>
    </div>
    """
  end

  def policy_blocked_panel(assigns) do
    ~H"""
    <section
      id="recording-policy-blocked-panel"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div class="flex items-center gap-2">
        <.ui_badge size="xs" variant="warning">Blocked — Stage B</.ui_badge>
        <h2 class="text-base font-semibold text-sr-ink">
          Continuous Recording Policy Prerequisite Gate
        </h2>
      </div>
      <p class="text-sm text-sr-muted">
        Per-camera continuous recording policy and pre-save capacity projection are blocked until
        their recording-plane and coordinator prerequisites land:
      </p>
      <ul class="list-disc pl-5 text-xs text-sr-muted space-y-1">
        <li>
          <strong>Continuous recording policy (<code class="font-mono">CameraRecordingPolicy</code>):</strong>
          per-camera mode (<code class="font-mono">off | continuous</code>), relay-eligible stream
          profile with observed bitrate and estimated bytes/blocks per day, explicit NVR member
          assignment transitions, storage mode (<code class="font-mono">local_and_archive | local_only</code>),
          and optional per-policy archive retention override (<code class="font-mono">add-scalable-camera-recording-plane</code>
          2.2, 2.4, 2.5 and <code class="font-mono">add-nvr-retention-and-timeline-playback</code>
          Stage A).
        </li>
        <li>
          <strong>Pre-save what-if projection:</strong>
          projected effective local window, required archive throughput against measured goodput,
          blocks per day against the volume block cap, and active sessions against the member session
          limit (<code class="font-mono">add-nvr-retention-and-timeline-playback</code>
          C1a, E1).
        </li>
      </ul>
    </section>
    """
  end

  attr :storage_mode, :atom, default: :local_only
  attr :can_manage?, :boolean, required: true
  attr :settings_record, :any, default: nil
  attr :settings_struct, :map, required: true
  attr :retention_form, :map, required: true
  attr :simulator_form, :map, required: true
  attr :retention_errors, :map, default: %{}
  attr :usage_summary, :map, required: true
  attr :projection, :map, required: true
  attr :object_retention_enforced?, :boolean, default: false
  attr :selected_retention_label, :string, default: "None selected (object retention not enforced)"
  attr :timezone, :string, default: "Etc/UTC"

  def retention_panel(assigns) do
    ~H"""
    <div id="recording-tab-panel-retention" class="space-y-6">
      <.retention_stage_banner
        storage_mode={@storage_mode}
        object_retention_enforced?={@object_retention_enforced?}
        shorter_archive_than_local?={@projection.shorter_archive_than_local?}
      />

      <.retention_usage_and_projection_card
        storage_mode={@storage_mode}
        usage_summary={@usage_summary}
        projection={@projection}
        retention_form={@retention_form}
        settings_struct={@settings_struct}
      />

      <form
        id="recording-retention-settings-form"
        phx-change="preview_retention_settings"
        phx-submit="save_retention_settings"
        class="space-y-6"
      >
        <.retention_what_if_card
          can_manage?={@can_manage?}
          simulator_form={@simulator_form}
        />

        <.retention_local_tier_card
          can_manage?={@can_manage?}
          retention_form={@retention_form}
          retention_errors={@retention_errors}
        />

        <.retention_local_only_card
          can_manage?={@can_manage?}
          settings_record={@settings_record}
          retention_form={@retention_form}
          retention_errors={@retention_errors}
          timezone={@timezone}
        />

        <.retention_object_archive_card
          storage_mode={@storage_mode}
          can_manage?={@can_manage?}
          settings_record={@settings_record}
          retention_form={@retention_form}
          retention_errors={@retention_errors}
          selected_retention_label={@selected_retention_label}
          object_retention_enforced?={@object_retention_enforced?}
          timezone={@timezone}
        />

        <p
          :if={@retention_errors[:base]}
          id="retention-error-base"
          class="text-xs text-rose-500"
        >
          {@retention_errors[:base]}
        </p>

        <div :if={@can_manage?} class="flex justify-end">
          <.ui_button id="save-retention-settings-btn" type="submit" variant="primary" size="sm">
            Save retention settings
          </.ui_button>
        </div>
      </form>
    </div>
    """
  end

  attr :storage_mode, :atom, required: true
  attr :object_retention_enforced?, :boolean, required: true
  attr :shorter_archive_than_local?, :boolean, required: true

  defp retention_stage_banner(assigns) do
    ~H"""
    <div class="space-y-3">
      <section
        id="recording-retention-stage-notice"
        class="rounded-xl border border-sr-line bg-sr-subtle/40 p-4 space-y-2"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex items-center gap-2">
            <.icon name="hero-clock" class="size-4 text-sr-ink" />
            <h2 class="text-sm font-semibold text-sr-ink">
              Deployment Retention Settings &amp; Live Capacity Calculator
            </h2>
          </div>
          <.ui_badge
            id="retention-storage-mode-badge"
            size="xs"
            variant={if(@storage_mode == :local_and_archive, do: "success", else: "ghost")}
          >
            {if @storage_mode == :local_and_archive,
              do: "Local + archive",
              else: "Local only: no object storage configured"}
          </.ui_badge>
        </div>
        <p class="text-xs text-sr-muted">
          Retention settings saved below persist in CNPG (<code class="font-mono">platform.camera_recording_archive_settings</code>)
          and drive live usage and window projections today. Automatic background eviction and deletion
          jobs (<code class="font-mono">LocalRetentionJob</code>, <code class="font-mono">ArchiveRetentionJob</code>, and the self-hosted object reaper, which
          remains behind a disabled flag with alerts only in Phase 1) activate once block cataloging
          and reconciliation land.
        </p>
      </section>

      <div
        :if={@storage_mode == :local_and_archive and !@object_retention_enforced?}
        id="retention-unenforced-banner"
        class="rounded-xl border border-amber-500/40 bg-amber-500/5 p-4 text-xs text-sr-ink"
      >
        <strong>Object retention not enforced: no delete credential.</strong>
        Select an <code class="font-mono">s3_compatible</code>
        retention delete credential on the
        <.link patch={~p"/settings/recording?#{%{tab: "archive"}}"} class="underline">
          Archive tab
        </.link>
        before expired or capacity-reaped archive objects can be deleted.
      </div>

      <div
        :if={@shorter_archive_than_local?}
        id="retention-shorter-archive-warning"
        role="status"
        class="rounded-xl border border-amber-500/40 bg-amber-500/5 p-4 text-xs text-sr-ink"
      >
        <strong>Single-copy local tail warning:</strong>
        configured object archive retention is shorter than the maximum local age ceiling. Archive
        copies will expire while their local copies remain, leaving that footage with a single local
        copy for the rest of its local life.
      </div>
    </div>
    """
  end

  attr :storage_mode, :atom, required: true
  attr :usage_summary, :map, required: true
  attr :projection, :map, required: true
  attr :retention_form, :map, required: true
  attr :settings_struct, :map, required: true

  defp retention_usage_and_projection_card(assigns) do
    ~H"""
    <section
      id="retention-usage-and-calculator-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            CNPG Usage &amp; Calculated Retention Summary
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Computed from verified <code class="font-mono">NVRArchiveReceipt</code> object lengths,
            Core <code class="font-mono">RecordingBlock</code> reservations, and your current draft
            inputs below (updates live before saving).
          </p>
        </div>
        <.ui_badge size="xs" variant="ghost">
          Rate basis: {format_rate_basis(@projection.rate.basis)}
        </.ui_badge>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div
          id="retention-metric-archive-used"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Archive object usage</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {format_bytes(@usage_summary.archive.archive_used_bytes)}
          </div>
          <div class="text-[11px] text-sr-muted">
            {@usage_summary.archive.archived_block_count} blocks ({@usage_summary.archive.archived_object_count} objects)
          </div>
        </div>

        <div
          id="retention-metric-archive-rates"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Trailing archive rates</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            24h: {format_bytes(@usage_summary.archive.trailing_24h_bytes)}/day
          </div>
          <div class="text-[11px] text-sr-muted font-mono">
            7d mean: {format_bytes(round(@usage_summary.archive.trailing_7d_daily_mean_bytes))}/day
          </div>
        </div>

        <div
          id="retention-metric-reserved-blocks"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Core reserved blocks</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            {@usage_summary.local_blocks.total_reserved_blocks} blocks
          </div>
          <div class="text-[11px] text-sr-muted">
            15m: {@usage_summary.local_blocks.trailing_15m_blocks} · 6h: {@usage_summary.local_blocks.trailing_6h_blocks}
          </div>
        </div>

        <div
          id="retention-metric-local-only-footage"
          class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 space-y-1"
        >
          <div class="text-xs text-sr-muted">Local-only &amp; held archive bytes</div>
          <div class="text-sm font-semibold font-mono text-sr-ink">
            Held: {format_bytes(@projection.object_projection.non_reapable_bytes)}
          </div>
          <div class="text-[11px] text-sr-muted">
            Local-only footage: 0 B (catalog pending)
          </div>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <div
          id="retention-calculated-local-summary"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-1.5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-xs font-semibold text-sr-ink">Projected Local Effective Window</h3>
            <.ui_badge size="xs" variant="ghost">
              {format_local_bound_badge(@projection.local_projection.binding_bound)}
            </.ui_badge>
          </div>
          <p class="text-sm font-medium text-sr-ink">
            {format_local_window_summary(@projection.local_projection)}
          </p>
          <p id="retention-local-time-to-full" class="text-xs text-sr-muted">
            Pinned-growth time-to-full:
            <strong class="text-sr-ink">
              {format_time_to_full(@projection.local_projection.time_to_full_seconds)}
            </strong>
            · Low/high water: {format_bytes(@projection.local_projection.low_water_bytes)} / {format_bytes(
              @projection.local_projection.high_water_bytes
            )}
          </p>
          <p
            :if={@projection.local_projection.below_window_alert?}
            id="retention-window-alert-warning"
            class="text-xs text-amber-500"
          >
            Projected low-water window is below the configured local window alert threshold.
          </p>
        </div>

        <div
          id="retention-calculated-object-summary"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-1.5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-xs font-semibold text-sr-ink">Projected Object Archive Retention</h3>
            <.ui_badge :if={@storage_mode == :local_only} size="xs" variant="ghost">
              Not used: local only
            </.ui_badge>
          </div>
          <p class="text-sm font-medium text-sr-ink">
            {format_object_retention_summary(@projection.object_projection)}
          </p>
          <p id="retention-days-to-capacity" class="text-xs text-sr-muted">
            Days to object capacity:
            <strong class="text-sr-ink">
              {format_days_to_capacity(@projection.object_projection.days_to_capacity)}
            </strong>
            <span :if={@projection.object_projection.hard_limit_bytes}>
              · Hard limit: {format_bytes(@projection.object_projection.hard_limit_bytes)}
            </span>
          </p>
        </div>
      </div>

      <div
        id="retention-eviction-preview"
        class="rounded-lg border border-sr-line bg-sr-canvas px-3.5 py-2.5 text-xs text-sr-muted"
      >
        <strong class="text-sr-ink">Pre-save consequence preview:</strong>
        {format_eviction_consequence_preview(@retention_form, @settings_struct, @projection)}
      </div>
    </section>
    """
  end

  attr :can_manage?, :boolean, required: true
  attr :simulator_form, :map, required: true

  defp retention_what_if_card(assigns) do
    ~H"""
    <section
      id="retention-what-if-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div>
        <h2 class="text-base font-semibold text-sr-ink">
          Interactive What-If Rate &amp; Spool Simulator
        </h2>
        <p class="mt-1 text-xs text-sr-muted">
          Optional simulator inputs recalculate the projected local window and object archive cutoff
          above on change (using the <code class="font-mono">1.02</code> CMAF overhead factor) without
          persisting to CNPG. Leave blank to use live CNPG history.
        </p>
      </div>

      <div class="grid gap-4 md:grid-cols-3">
        <div>
          <label for="simulator-camera-count-input" class="block text-xs font-medium text-sr-ink">
            Simulated camera count
          </label>
          <input
            id="simulator-camera-count-input"
            type="number"
            min="0"
            name="simulator[camera_count]"
            value={@simulator_form["camera_count"]}
            disabled={!@can_manage?}
            placeholder="e.g. 4"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
        </div>

        <div>
          <label for="simulator-bitrate-kbps-input" class="block text-xs font-medium text-sr-ink">
            Nominal bitrate per camera (kbit/s)
          </label>
          <input
            id="simulator-bitrate-kbps-input"
            type="number"
            min="0"
            name="simulator[nominal_bitrate_kbps]"
            value={@simulator_form["nominal_bitrate_kbps"]}
            disabled={!@can_manage?}
            placeholder="e.g. 2000"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
        </div>

        <div>
          <label
            for="simulator-local-budget-gib-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Simulated local spool budget (GiB)
          </label>
          <input
            id="simulator-local-budget-gib-input"
            type="number"
            min="1"
            name="simulator[local_budget_gib]"
            value={@simulator_form["local_budget_gib"]}
            disabled={!@can_manage?}
            placeholder="e.g. 84"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
        </div>
      </div>
    </section>
    """
  end

  attr :can_manage?, :boolean, required: true
  attr :retention_form, :map, required: true
  attr :retention_errors, :map, required: true

  defp retention_local_tier_card(assigns) do
    ~H"""
    <section
      id="retention-local-tier-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div>
        <h2 class="text-base font-semibold text-sr-ink">
          Local Tier Watermarks &amp; Maximum Local Age Ceiling
        </h2>
        <p class="mt-1 text-xs text-sr-muted">
          Space eviction starts at high water (<code class="font-mono">50..95%</code>) and stops at
          low water (<code class="font-mono">40..high-5%</code>). Maximum local age is an upper
          ceiling (<code class="font-mono">1h..10y</code>, default
          <code class="font-mono">86,400</code>
          s)
          or unlimited; unarchived and unreconciled blocks are never evicted.
        </p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <div>
          <label
            for="retention-local-high-water-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Local high-water mark (%)
          </label>
          <input
            id="retention-local-high-water-input"
            type="number"
            min="50"
            max="95"
            name="retention[local_high_water_percent]"
            value={@retention_form["local_high_water_percent"]}
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:local_high_water_percent]}
            id="retention-error-local-high-water"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:local_high_water_percent]}
          </p>
        </div>

        <div>
          <label
            for="retention-local-low-water-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Local low-water mark (%, at most high water minus 5)
          </label>
          <input
            id="retention-local-low-water-input"
            type="number"
            min="40"
            max="90"
            name="retention[local_low_water_percent]"
            value={@retention_form["local_low_water_percent"]}
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:local_low_water_percent]}
            id="retention-error-local-low-water"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:local_low_water_percent]}
          </p>
        </div>

        <div>
          <label
            for="retention-max-local-age-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Maximum local age ceiling mode
          </label>
          <select
            id="retention-max-local-age-mode-select"
            name="retention[max_local_age_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option value="limited" selected={@retention_form["max_local_age_mode"] == "limited"}>
              Limited ceiling (seconds)
            </option>
            <option
              value="unlimited"
              selected={@retention_form["max_local_age_mode"] == "unlimited"}
            >
              No limit
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-max-local-age-seconds-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Maximum local age seconds (<code class="font-mono">3,600..315,360,000</code>)
          </label>
          <input
            id="retention-max-local-age-seconds-input"
            type="number"
            min="3600"
            max="315360000"
            name="retention[max_local_age_seconds]"
            value={@retention_form["max_local_age_seconds"]}
            disabled={!@can_manage? or @retention_form["max_local_age_mode"] != "limited"}
            placeholder="86400"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:max_local_age_seconds]}
            id="retention-error-max-local-age"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:max_local_age_seconds]}
          </p>
        </div>

        <div>
          <label
            for="retention-local-window-alert-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Effective local window alert
          </label>
          <select
            id="retention-local-window-alert-mode-select"
            name="retention[local_window_alert_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="enabled"
              selected={@retention_form["local_window_alert_mode"] == "enabled"}
            >
              Enabled
            </option>
            <option
              value="disabled"
              selected={@retention_form["local_window_alert_mode"] == "disabled"}
            >
              Disabled
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-local-window-alert-seconds-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Window alert threshold seconds (<code class="font-mono">60..31,536,000</code>)
          </label>
          <input
            id="retention-local-window-alert-seconds-input"
            type="number"
            min="60"
            max="31536000"
            name="retention[local_window_alert_seconds]"
            value={@retention_form["local_window_alert_seconds"]}
            disabled={!@can_manage? or @retention_form["local_window_alert_mode"] != "enabled"}
            placeholder="3600"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:local_window_alert_seconds]}
            id="retention-error-local-window-alert"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:local_window_alert_seconds]}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :can_manage?, :boolean, required: true
  attr :settings_record, :any, default: nil
  attr :retention_form, :map, required: true
  attr :retention_errors, :map, required: true
  attr :timezone, :string, required: true

  defp retention_local_only_card(assigns) do
    persisted_policy = assigns.settings_record && Map.get(assigns.settings_record, :local_only_full_policy)
    confirmed_by = assigns.settings_record && Map.get(assigns.settings_record, :local_only_full_policy_confirmed_by_id)
    confirmed_at = assigns.settings_record && Map.get(assigns.settings_record, :local_only_full_policy_confirmed_at)

    assigns =
      assigns
      |> assign(:persisted_policy, persisted_policy)
      |> assign(:confirmed_by, confirmed_by)
      |> assign(:confirmed_at, confirmed_at)

    ~H"""
    <section
      id="retention-local-only-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Local-Only Mode Policy</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Governs <code class="font-mono">not_required</code> local-only footage when object
            storage is off or a camera policy is <code class="font-mono">local_only</code>. Until an
            operator confirms a full policy, runtime behaviour is <code class="font-mono">stop_when_full</code>.
          </p>
        </div>
        <.ui_badge
          id="retention-local-only-effective-state"
          size="xs"
          variant={if(@persisted_policy, do: "success", else: "ghost")}
        >
          {if @persisted_policy,
            do: "Confirmed: #{@persisted_policy}",
            else: "Unset (behaves as stop_when_full)"}
        </.ui_badge>
      </div>

      <p
        :if={@persisted_policy && @confirmed_by}
        id="retention-local-only-confirmed-audit"
        class="text-xs text-sr-muted"
      >
        Confirmed by <code class="font-mono">{@confirmed_by}</code>
        <span :if={@confirmed_at}>
          at
          <.user_time
            id="local-only-confirmed-at"
            value={@confirmed_at}
            timezone={@timezone}
            style={:compact}
          />
        </span>
      </p>

      <div class="grid gap-4 md:grid-cols-2">
        <div class="md:col-span-2 space-y-2">
          <label
            for="retention-local-only-full-policy-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Local-only full policy
          </label>
          <select
            id="retention-local-only-full-policy-select"
            name="retention[local_only_full_policy]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="overwrite_oldest"
              selected={@retention_form["local_only_full_policy"] == "overwrite_oldest"}
            >
              overwrite_oldest — ring buffer (evicts oldest unheld local-only blocks at high water)
            </option>
            <option
              value="stop_when_full"
              selected={@retention_form["local_only_full_policy"] == "stop_when_full"}
            >
              stop_when_full — never evict for space; refuse admission when budget fills
            </option>
            <option value="" selected={@retention_form["local_only_full_policy"] in [nil, ""]}>
              Leave unset (behaves as stop_when_full)
            </option>
          </select>

          <div
            :if={@retention_form["local_only_full_policy"] == "overwrite_oldest"}
            class="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 space-y-2"
          >
            <p class="text-xs text-sr-ink">
              With no archive copy, <code class="font-mono">overwrite_oldest</code> permanently
              deletes the only copy of the oldest unheld local-only blocks once usage reaches high
              water.
            </p>
            <label class="inline-flex items-center gap-2 text-xs font-medium text-sr-ink">
              <input type="hidden" name="retention[confirm_local_only_overwrite]" value="false" />
              <input
                id="retention-confirm-local-only-overwrite"
                type="checkbox"
                name="retention[confirm_local_only_overwrite]"
                value="true"
                checked={@retention_form["confirm_local_only_overwrite"] == "true"}
                disabled={!@can_manage?}
                class="rounded border-sr-line"
              />
              <span>
                I confirm <code class="font-mono">overwrite_oldest</code> may delete the only copy
                of local-only footage when local storage reaches high water.
              </span>
            </label>
          </div>

          <p
            :if={@retention_errors[:local_only_full_policy]}
            id="retention-error-local-only-full-policy"
            class="text-xs text-rose-500"
          >
            {@retention_errors[:local_only_full_policy]}
          </p>
        </div>

        <div>
          <label
            for="retention-local-only-target-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Local-only retention target alert
          </label>
          <select
            id="retention-local-only-target-mode-select"
            name="retention[local_only_target_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="target"
              selected={@retention_form["local_only_target_mode"] == "target"}
            >
              Alert target enabled (default 7 days)
            </option>
            <option value="none" selected={@retention_form["local_only_target_mode"] == "none"}>
              None (alert off)
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-local-only-target-seconds-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Local-only target seconds (<code class="font-mono">3,600..315,360,000</code>)
          </label>
          <input
            id="retention-local-only-target-seconds-input"
            type="number"
            min="3600"
            max="315360000"
            name="retention[local_only_retention_target_seconds]"
            value={@retention_form["local_only_retention_target_seconds"]}
            disabled={!@can_manage? or @retention_form["local_only_target_mode"] != "target"}
            placeholder="604800"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:local_only_retention_target_seconds]}
            id="retention-error-local-only-target"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:local_only_retention_target_seconds]}
          </p>
        </div>

        <div>
          <label
            for="retention-local-only-max-age-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Local-only maximum age ceiling
          </label>
          <select
            id="retention-local-only-max-age-mode-select"
            name="retention[local_only_max_age_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="unlimited"
              selected={@retention_form["local_only_max_age_mode"] == "unlimited"}
            >
              Keep until the volume is full
            </option>
            <option
              value="limited"
              selected={@retention_form["local_only_max_age_mode"] == "limited"}
            >
              Limited age ceiling (seconds)
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-local-only-max-age-seconds-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Local-only maximum age seconds (<code class="font-mono">3,600..315,360,000</code>)
          </label>
          <input
            id="retention-local-only-max-age-seconds-input"
            type="number"
            min="3600"
            max="315360000"
            name="retention[local_only_max_age_seconds]"
            value={@retention_form["local_only_max_age_seconds"]}
            disabled={!@can_manage? or @retention_form["local_only_max_age_mode"] != "limited"}
            placeholder="604800"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:local_only_max_age_seconds]}
            id="retention-error-local-only-max-age"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:local_only_max_age_seconds]}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :storage_mode, :atom, required: true
  attr :can_manage?, :boolean, required: true
  attr :settings_record, :any, default: nil
  attr :retention_form, :map, required: true
  attr :retention_errors, :map, required: true
  attr :selected_retention_label, :string, required: true
  attr :object_retention_enforced?, :boolean, required: true
  attr :timezone, :string, required: true

  defp retention_object_archive_card(assigns) do
    persisted_cap = assigns.settings_record && Map.get(assigns.settings_record, :object_capacity_policy)
    confirmed_by = assigns.settings_record && Map.get(assigns.settings_record, :object_capacity_policy_confirmed_by_id)
    confirmed_at = assigns.settings_record && Map.get(assigns.settings_record, :object_capacity_policy_confirmed_at)

    assigns =
      assigns
      |> assign(:persisted_cap, persisted_cap)
      |> assign(:confirmed_by, confirmed_by)
      |> assign(:confirmed_at, confirmed_at)

    ~H"""
    <section
      id="retention-object-archive-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">
            Object Archive Retention &amp; Self-Hosted Object Budget
          </h2>
          <p class="mt-1 text-xs text-sr-muted">
            Application-managed archive expiry (<code class="font-mono">1..3,650</code>
            days, default <code class="font-mono">30</code>, or unlimited) and optional byte budget using the
            <code class="font-mono">:retention</code>
            delete credential (<code class="font-mono">{@selected_retention_label}</code>).
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.ui_badge
            :if={@storage_mode == :local_only}
            id="retention-archive-local-only-indicator"
            size="xs"
            variant="ghost"
          >
            Not used: local only
          </.ui_badge>
          <.ui_badge
            id="retention-object-capacity-effective-state"
            size="xs"
            variant={if(@persisted_cap, do: "success", else: "ghost")}
          >
            {if @persisted_cap,
              do: "Confirmed: #{@persisted_cap}",
              else: "Unset (behaves as stop_archiving)"}
          </.ui_badge>
        </div>
      </div>

      <p
        id="retention-reaper-flag-notice"
        class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3 text-xs text-sr-muted"
      >
        <strong class="text-sr-ink">Self-hosted Phase 1 reaper notice:</strong>
        the self-hosted object budget computes effective retention and raises capacity alerts only
        while the object reaper flag remains disabled.
      </p>

      <p
        :if={@persisted_cap && @confirmed_by}
        id="retention-object-capacity-confirmed-audit"
        class="text-xs text-sr-muted"
      >
        Confirmed by <code class="font-mono">{@confirmed_by}</code>
        <span :if={@confirmed_at}>
          at
          <.user_time
            id="object-capacity-confirmed-at"
            value={@confirmed_at}
            timezone={@timezone}
            style={:compact}
          />
        </span>
      </p>

      <div class="grid gap-4 md:grid-cols-2">
        <div>
          <label
            for="retention-archive-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Object archive retention mode
          </label>
          <select
            id="retention-archive-mode-select"
            name="retention[archive_retention_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="limited"
              selected={@retention_form["archive_retention_mode"] == "limited"}
            >
              Limited days (default 30)
            </option>
            <option
              value="unlimited"
              selected={@retention_form["archive_retention_mode"] == "unlimited"}
            >
              No limit
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-archive-days-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Archive retention days (<code class="font-mono">1..3,650</code>)
          </label>
          <input
            id="retention-archive-days-input"
            type="number"
            min="1"
            max="3650"
            name="retention[archive_retention_days]"
            value={@retention_form["archive_retention_days"]}
            disabled={!@can_manage? or @retention_form["archive_retention_mode"] != "limited"}
            placeholder="30"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:archive_retention_days]}
            id="retention-error-archive-retention-days"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:archive_retention_days]}
          </p>
        </div>

        <div>
          <label
            for="retention-object-budget-mode-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Object byte budget mode
          </label>
          <select
            id="retention-object-budget-mode-select"
            name="retention[object_budget_mode]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option
              value="unlimited"
              selected={@retention_form["object_budget_mode"] == "unlimited"}
            >
              No limit
            </option>
            <option value="limited" selected={@retention_form["object_budget_mode"] == "limited"}>
              Limited byte budget (&gt;= 1 GiB)
            </option>
          </select>
        </div>

        <div>
          <label
            for="retention-object-budget-bytes-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Object budget bytes (&gt;= <code class="font-mono">1,073,741,824</code>)
          </label>
          <input
            id="retention-object-budget-bytes-input"
            type="number"
            min="1073741824"
            name="retention[object_budget_bytes]"
            value={@retention_form["object_budget_bytes"]}
            disabled={!@can_manage? or @retention_form["object_budget_mode"] != "limited"}
            placeholder="10737418240"
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:object_budget_bytes]}
            id="retention-error-object-budget-bytes"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:object_budget_bytes]}
          </p>
        </div>

        <div>
          <label
            for="retention-object-high-water-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Object high-water mark (%)
          </label>
          <input
            id="retention-object-high-water-input"
            type="number"
            min="50"
            max="95"
            name="retention[object_high_water_percent]"
            value={@retention_form["object_high_water_percent"]}
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:object_high_water_percent]}
            id="retention-error-object-high-water"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:object_high_water_percent]}
          </p>
        </div>

        <div>
          <label
            for="retention-object-low-water-input"
            class="block text-xs font-medium text-sr-ink"
          >
            Object low-water mark (%, at most high water minus 5)
          </label>
          <input
            id="retention-object-low-water-input"
            type="number"
            min="40"
            max="90"
            name="retention[object_low_water_percent]"
            value={@retention_form["object_low_water_percent"]}
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          />
          <p
            :if={@retention_errors[:object_low_water_percent]}
            id="retention-error-object-low-water"
            class="mt-1 text-xs text-rose-500"
          >
            {@retention_errors[:object_low_water_percent]}
          </p>
        </div>

        <div class="md:col-span-2 space-y-2">
          <label
            for="retention-object-capacity-policy-select"
            class="block text-xs font-medium text-sr-ink"
          >
            Object capacity policy (required when object budget is limited)
          </label>
          <select
            id="retention-object-capacity-policy-select"
            name="retention[object_capacity_policy]"
            disabled={!@can_manage?}
            class="mt-1 w-full rounded-lg border border-sr-line bg-sr-canvas px-3 py-2 text-sm text-sr-ink disabled:opacity-60"
          >
            <option value="" selected={@retention_form["object_capacity_policy"] in [nil, ""]}>
              Leave unset (behaves as stop_archiving)
            </option>
            <option
              value="reap_oldest"
              selected={@retention_form["object_capacity_policy"] == "reap_oldest"}
            >
              reap_oldest — delete oldest unheld archive copies from high water down to low water
            </option>
            <option
              value="stop_archiving"
              selected={@retention_form["object_capacity_policy"] == "stop_archiving"}
            >
              stop_archiving — pause archive uploads at hard limit and keep footage pending locally
            </option>
          </select>

          <p id="retention-reap-oldest-statement" class="text-xs text-sr-muted">
            Note: <code class="font-mono">reap_oldest</code> can delete the last copy of footage
            once the local copy has been evicted, and can delete the last copy, including by later
            local eviction of blocks whose archive copy was reaped.
          </p>

          <div
            :if={@retention_form["object_capacity_policy"] == "reap_oldest"}
            class="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 space-y-2"
          >
            <label class="inline-flex items-center gap-2 text-xs font-medium text-sr-ink">
              <input type="hidden" name="retention[confirm_reap_oldest]" value="false" />
              <input
                id="retention-confirm-reap-oldest"
                type="checkbox"
                name="retention[confirm_reap_oldest]"
                value="true"
                checked={@retention_form["confirm_reap_oldest"] == "true"}
                disabled={!@can_manage?}
                class="rounded border-sr-line"
              />
              <span>
                I confirm <code class="font-mono">reap_oldest</code> can delete the last copy,
                including by later local eviction of blocks whose archive copy was reaped.
              </span>
            </label>
          </div>

          <p
            :if={@retention_errors[:object_capacity_policy]}
            id="retention-error-object-capacity-policy"
            class="text-xs text-rose-500"
          >
            {@retention_errors[:object_capacity_policy]}
          </p>
        </div>
      </div>
    </section>
    """
  end

  def health_blocked_panel(assigns) do
    ~H"""
    <section
      id="recording-health-blocked-panel"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-3"
    >
      <div class="flex items-center gap-2">
        <.ui_badge size="xs" variant="warning">Blocked — Stage B</.ui_badge>
        <h2 class="text-base font-semibold text-sr-ink">
          Recording, Reconciliation &amp; Archive Health Prerequisite Gate
        </h2>
      </div>
      <p class="text-sm text-sr-muted">
        Per-recorder pending archive backlog, oldest pending age, goodput-vs-capture
        (<code class="font-mono">U &lt;= R</code> non-draining backlog), reconciliation status,
        effective local window, and deduplicated storage alerts are blocked until their telemetry and
        reconciler prerequisites land:
      </p>
      <ul class="list-disc pl-5 text-xs text-sr-muted space-y-1">
        <li>
          <strong>Continuous block sealing, reconciler &amp; archive outbox:</strong>
          requires <code class="font-mono">add-scalable-camera-recording-plane</code>
          task 3.2 and <code class="font-mono">add-nvr-retention-and-timeline-playback</code>
          Stage R
          (<code class="font-mono">NVRReconcileJob</code>
          unreconciled and unattributable reporting).
        </li>
        <li>
          <strong>JetStream recording telemetry &amp; deduplicated alerts:</strong>
          requires backlog and goodput publication to NATS JetStream
          (<code class="font-mono">metrics.timeseries.recording.*</code>, task 3.5) persisted by
          <code class="font-mono">EventWriter</code>
          into the telemetry store, plus <code class="font-mono">TripwireHealth</code>
          storage checks, 24-hour gap summaries, and
          inventory ledger status.
        </li>
      </ul>
    </section>
    """
  end

  # --- formatting helpers ----------------------------------------------------

  defp format_object_retention_summary(%{policies: [pol | _]} = obj_proj) do
    cfg = pol.configured_days
    eff = pol.effective_days
    bound = pol.binding_bound

    paused_suffix =
      if Map.get(obj_proj, :archiving_paused?), do: " — archiving paused for capacity", else: ""

    cond do
      cfg == :unlimited and eff == :unlimited ->
        "Object archive holds unlimited — configured unlimited, effective unlimited#{paused_suffix}"

      cfg == :unlimited and is_number(eff) ->
        d = format_days(eff)

        "Object archive holds about #{d} days — configured unlimited, effective about #{d} days (capacity binds)#{paused_suffix}"

      is_number(cfg) and bound == :time ->
        d = format_days(eff)

        "Object archive holds about #{d} days — configured #{cfg} days, effective about #{d} days (time binds)#{paused_suffix}"

      is_number(cfg) and is_number(eff) ->
        d = format_days(eff)

        "Object archive holds about #{d} days — configured #{cfg} days, effective about #{d} days (capacity binds)#{paused_suffix}"

      true ->
        "Object archive retention unlimited#{paused_suffix}"
    end
  end

  defp format_object_retention_summary(_), do: "Object archive retention unlimited"

  defp format_local_window_summary(local_proj) do
    status = Map.get(local_proj, :status, :not_recording)
    low = Map.get(local_proj, :window_low_seconds, 0.0)
    high = Map.get(local_proj, :window_high_seconds, 0.0)
    rate = Map.get(local_proj, :rate_bytes_per_sec, 0.0)
    bound = Map.get(local_proj, :binding_bound, :budget)

    cond do
      status == :not_recording ->
        "Not recording — no active camera rate or recent block reservations"

      status == :no_recent_ingest and rate <= 0.0 ->
        "No recent ingest — enter simulated camera count and bitrate below to preview estimated window"

      low == :until_policy_or_age_changes ->
        "Kept until full policy or local-only maximum age changes (local-only cameras consume space that cannot be freed)"

      low == :infinity ->
        "Local storage holds unlimited at the current rate"

      is_number(low) and is_number(high) ->
        basis_note = if status == :estimated, do: ", estimated", else: ""

        "Local storage holds about #{format_window_range(low, high)} at the current rate (#{format_local_bound_text(bound)}#{basis_note})"

      true ->
        "Not recording"
    end
  end

  defp format_window_range(low_sec, high_sec) when is_number(low_sec) and is_number(high_sec) do
    cond do
      high_sec <= 0.0 ->
        "0 minutes"

      abs(high_sec - low_sec) < 1.0 ->
        format_window_span(low_sec)

      high_sec < 3_600.0 ->
        "#{format_num(low_sec / 60.0)} to #{format_num(high_sec / 60.0)} minutes"

      true ->
        "#{format_num(low_sec / 3_600.0)} to #{format_num(high_sec / 3_600.0)} hours"
    end
  end

  defp format_window_span(seconds) when seconds < 3_600.0 do
    "#{format_num(seconds / 60.0)} minutes"
  end

  defp format_window_span(seconds) do
    "#{format_num(seconds / 3_600.0)} hours"
  end

  defp format_local_bound_text(:max_age), do: "maximum age binds"
  defp format_local_bound_text(:block_cap), do: "block cap binds"
  defp format_local_bound_text(:pinned), do: "pinned under stop_when_full"
  defp format_local_bound_text(:unlimited_budget), do: "until local budget fills"
  defp format_local_bound_text(_), do: "budget binds"

  defp format_local_bound_badge(:not_recording), do: "Not recording"
  defp format_local_bound_badge(:no_recent_ingest), do: "No recent ingest"
  defp format_local_bound_badge(:max_age), do: "Age ceiling"
  defp format_local_bound_badge(:block_cap), do: "Block cap"
  defp format_local_bound_badge(:pinned), do: "Pinned"
  defp format_local_bound_badge(_), do: "Budget"

  defp format_time_to_full(:not_filling), do: "not filling"
  defp format_time_to_full(sec) when is_number(sec), do: "about #{format_window_span(sec)}"
  defp format_time_to_full(_), do: "not filling"

  defp format_days_to_capacity(:not_filling), do: "not filling"
  defp format_days_to_capacity(days) when is_number(days), do: "about #{format_days(days)} days"
  defp format_days_to_capacity(_), do: "not filling"

  defp format_rate_basis(:measured), do: "measured (CNPG)"
  defp format_rate_basis(:estimated), do: "estimated (what-if)"
  defp format_rate_basis(_), do: "no 24h history"

  defp format_eviction_consequence_preview(form, saved, projection) do
    local_range = "#{form["local_low_water_percent"]}%..#{form["local_high_water_percent"]}%"

    local_age =
      if form["max_local_age_mode"] == "unlimited",
        do: "no local age limit",
        else: "max local age #{form["max_local_age_seconds"]} s"

    saved_days = Map.get(saved, :archive_retention_days)
    draft_days = form["archive_retention_days"]

    obj_cutoff =
      case projection.object_projection do
        %{policies: [%{effective_days: :unlimited} | _]} -> "unlimited object retention"
        %{policies: [%{effective_days: d} | _]} when is_number(d) -> "effective archive cutoff ~#{format_days(d)} days"
        _ -> "unlimited object retention"
      end

    tightened_note =
      if is_integer(saved_days) and form["archive_retention_mode"] == "limited" and
           String.trim(draft_days || "") != "" and
           match?({n, ""} when n < saved_days, Integer.parse(String.trim(draft_days))) do
        " (shortens saved #{saved_days}-day archive retention; older archive copies become eligible once ArchiveRetentionJob activates)"
      else
        ""
      end

    "Local eviction band #{local_range} (#{local_age}); #{obj_cutoff}#{tightened_note}."
  end

  defp format_days(val) when is_integer(val), do: Integer.to_string(val)

  defp format_days(val) when is_float(val) do
    format_num(val)
  end

  defp format_num(val) when is_number(val) do
    rounded = Float.round(val * 1.0, 1)

    if rounded == Float.floor(rounded) do
      rounded |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_073_741_824 do
    "#{format_num(bytes / 1_073_741_824)} GiB"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_048_576 do
    "#{format_num(bytes / 1_048_576)} MiB"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_024 do
    "#{format_num(bytes / 1_024)} KiB"
  end

  defp format_bytes(bytes) when is_number(bytes) do
    "#{trunc(bytes)} B"
  end

  defp format_bytes(_), do: "0 B"

  defp format_receipt_object(obj) when is_map(obj) do
    name = obj["name"] || obj[:name]
    key = obj["key"] || obj[:key]
    len = obj["length"] || obj[:length]
    sha_prefix = obj["sha256"] |> Kernel.||(obj[:sha256]) |> to_string() |> String.slice(0, 12)

    version_suffix =
      case obj["version_id"] || obj[:version_id] do
        v when is_binary(v) and v != "" -> ", version #{v}"
        _ -> ""
      end

    "#{name}: #{key} (#{len} B, sha256 #{sha_prefix}…#{version_suffix})"
  end

  defp format_receipt_object(_), do: ""

  defp nvr_install_label(:installed), do: "Installed"
  defp nvr_install_label(:not_installed), do: "Not installed"
  defp nvr_install_label(:invalid_config), do: "Invalid configuration"
  defp nvr_install_label(:unknown), do: "Unknown"

  defp nvr_install_badge_variant(:installed), do: "success"
  defp nvr_install_badge_variant(:not_installed), do: "ghost"
  defp nvr_install_badge_variant(:invalid_config), do: "error"
  defp nvr_install_badge_variant(:unknown), do: "warning"

  defp gate_label(:open), do: "Open"
  defp gate_label(:closed), do: "Closed"
  defp gate_label(:not_configured), do: "Not configured"
  defp gate_label(:unknown), do: "Unknown"

  defp gate_badge_variant(:open), do: "success"
  defp gate_badge_variant(:closed), do: "error"
  defp gate_badge_variant(:not_configured), do: "warning"
  defp gate_badge_variant(:unknown), do: "ghost"

  defp reachability_label(:reachable), do: "Reachable"
  defp reachability_label(:unreachable), do: "Unknown (unreachable)"
  defp reachability_label(:unknown), do: "Unknown"

  defp reachability_badge_variant(:reachable), do: "success"
  defp reachability_badge_variant(:unreachable), do: "warning"
  defp reachability_badge_variant(:unknown), do: "ghost"

  defp supervisor_label(:enabled), do: "Enabled"
  defp supervisor_label(:disabled), do: "Disabled"
  defp supervisor_label(:unknown), do: "Unknown"

  defp supervisor_badge_variant(:enabled), do: "success"
  defp supervisor_badge_variant(:disabled), do: "ghost"
  defp supervisor_badge_variant(:unknown), do: "warning"
end
