defmodule ServiceRadarWebNGWeb.Settings.RecordingLive.Components do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  @tabs [
    %{id: "recorders", label: "Recorders", stage_b?: false},
    %{id: "archive", label: "Archive", stage_b?: false},
    %{id: "cameras", label: "Cameras", stage_b?: false},
    %{id: "policy", label: "Policy & Retention", stage_b?: true},
    %{id: "health", label: "Archive Health", stage_b?: true}
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
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Recorder Runtime &amp; Spool Policy</h2>
          <p class="mt-1 text-sm text-sr-muted">
            Per-member readiness, member recovery gate state, and spool capacity are reported as
            <strong>unknown</strong>
            until the NVR member status endpoint answers; unreachable or unexposed members are never
            rendered as an empty recorder list.
          </p>
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
          id="recording-local-retention-notice"
          class="rounded-lg border border-sr-line bg-sr-subtle/40 p-3 text-xs text-sr-muted"
        >
          <strong class="text-sr-ink">Hot local retention is not yet enforced:</strong>
          local blocks are not reclaimed by age, and new bounded captures are refused when recorder
          spool capacity is exhausted.
        </div>
      </section>
    </div>
    """
  end

  attr :runtime, :map, required: true
  attr :bindings, :list, required: true
  attr :credentials, :list, required: true
  attr :can_manage?, :boolean, required: true
  attr :can_manage_credentials?, :boolean, required: true
  attr :settings_form, :map, required: true
  attr :destination_form, :map, required: true
  attr :destination_errors, :map, required: true
  attr :selected_writer_label, :string, required: true
  attr :selected_reader_label, :string, required: true
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

  defp archive_settings_card(assigns) do
    ~H"""
    <section
      id="recording-archive-settings-card"
      class="rounded-xl border border-sr-line bg-sr-surface p-5 space-y-4"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold text-sr-ink">Active Archive Configuration</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Select the active immutable destination generation, enable or pause operator archive
            uploads, and bind reusable <code class="font-mono">s3_compatible</code> credentials by
            identifier. Secret key material is never entered or displayed here.
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
                None selected
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

        <div class="grid gap-4 md:grid-cols-2">
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
        </div>

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
        credentials exist yet. Create one in <.link
          navigate={~p"/settings/networks/credentials"}
          class="underline"
        >
          Credentials settings
        </.link>.
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
        No archive destination generations have been registered yet.
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
                        {obj["name"] || obj[:name]}: {obj["key"] || obj[:key]} ({obj["length"] ||
                          obj[:length]} B, sha256 {String.slice(
                          to_string(obj["sha256"] || obj[:sha256]),
                          0,
                          12
                        )}…)
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
          Recording Policy &amp; Hot Retention Prerequisite Gate
        </h2>
      </div>
      <p class="text-sm text-sr-muted">
        Continuous per-camera recording policy and hot local retention reclamation are blocked until
        their recording-plane prerequisites land:
      </p>
      <ul class="list-disc pl-5 text-xs text-sr-muted space-y-1">
        <li>
          <strong>Continuous recording policy (<code class="font-mono">CameraRecordingPolicy</code>):</strong>
          requires recorder pools and placement (<code class="font-mono">add-scalable-camera-recording-plane</code>
          2.2),
          viewerless continuous capture (2.4), and assignment transition handoff (2.5).
        </li>
        <li>
          <strong>Automatic archive &amp; hot local retention (24-hour / 86,400 s CNPG default):</strong>
          requires continuous sealing and journal/outbox (3.2), local block registration (3.3),
          receipt-based reclamation proofs (3.4), and VMS holds/exports
          (<code class="font-mono">add-vms-storage-playback-engine</code>). Unarchived blocks are never
          reclaimed by age.
        </li>
      </ul>
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
          Archive Backlog &amp; Goodput Health Prerequisite Gate
        </h2>
      </div>
      <p class="text-sm text-sr-muted">
        Per-recorder pending archive backlog, oldest pending age, and goodput-vs-capture
        (<code class="font-mono">U &lt;= R</code> non-draining backlog) reporting are blocked until
        their recording-plane telemetry prerequisites land:
      </p>
      <ul class="list-disc pl-5 text-xs text-sr-muted space-y-1">
        <li>
          <strong>Continuous block sealing &amp; archive outbox:</strong>
          requires <code class="font-mono">add-scalable-camera-recording-plane</code>
          task 3.2.
        </li>
        <li>
          <strong>JetStream recording telemetry:</strong>
          requires NVR backlog and goodput publication to NATS JetStream
          (<code class="font-mono">metrics.timeseries.recording.*</code>, task 3.5) persisted by
          <code class="font-mono">EventWriter</code>
          into the telemetry store.
        </li>
      </ul>
    </section>
    """
  end

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
