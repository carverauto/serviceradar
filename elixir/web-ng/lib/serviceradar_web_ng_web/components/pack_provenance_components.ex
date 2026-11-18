defmodule ServiceRadarWebNGWeb.Components.PackProvenanceComponents do
  @moduledoc """
  Shared Managed Solution Pack provenance banners and structural-edit fork
  confirmation modals (`4.4`) used across the Observability Rule editors
  (`StatefulAlertRule`, `EventRule`, `ZenRule`) and Authored Dashboard builder,
  matching `DeclarativeCheckLive.Edit`.
  """

  use ServiceRadarWebNGWeb, :html

  attr :pack_id, :string, default: nil
  attr :pack_version, :string, default: nil
  attr :managed, :boolean, default: false
  attr :resource_kind, :string, default: "resource"
  attr :class, :string, default: nil

  def pack_provenance_banner(assigns) do
    ~H"""
    <div
      :if={is_binary(@pack_id) and @pack_id != ""}
      data-role="pack-provenance-banner"
      class={[
        "rounded-lg border px-4 py-3 text-sm",
        if(@managed,
          do: "border-sr-brand/30 bg-sr-brand/5 text-sr-ink",
          else: "border-sr-line bg-sr-subtle text-sr-muted"
        ),
        @class
      ]}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-wrap items-center gap-2">
          <.icon
            name={if(@managed, do: "hero-cube-transparent", else: "hero-code-bracket-square")}
            class="size-4 text-sr-brand shrink-0"
          />
          <span class="font-semibold text-sr-ink">
            {if(@managed, do: "Managed Solution Pack", else: "Detached from Solution Pack")}
          </span>
          <.ui_badge variant={if(@managed, do: "info", else: "outline")} size="xs">
            {@pack_id}
          </.ui_badge>
          <.ui_badge :if={is_binary(@pack_version) and @pack_version != ""} variant="ghost" size="xs">
            v{@pack_version}
          </.ui_badge>
          <.ui_badge variant={if(@managed, do: "success", else: "warning")} size="xs">
            {if(@managed, do: "managed: true", else: "managed: false (forked)")}
          </.ui_badge>
        </div>

        <.link
          navigate={~p"/catalog"}
          class="text-xs font-medium text-sr-brand hover:text-sr-brand-strong"
        >
          View in Catalog
        </.link>
      </div>

      <p class="mt-1.5 text-xs text-sr-muted">
        <%= if @managed do %>
          Parameter and threshold edits save into <code class="font-mono">parameter_overrides</code>
          and are preserved on Solution Pack upgrades. Structural edits require detaching this {@resource_kind} (<code class="font-mono">managed: false</code>).
        <% else %>
          This {@resource_kind} was forked from <code class="font-mono">{@pack_id}</code>.
          Future Solution Pack upgrades will protect your custom structure unless you explicitly reset to upstream.
        <% end %>
      </p>
    </div>
    """
  end

  attr :id, :string, default: "pack-fork-confirmation-modal"
  attr :open, :boolean, default: false
  attr :resource_label, :string, required: true
  attr :pack_id, :string, default: nil
  attr :pack_version, :string, default: nil
  attr :allow_override_save, :boolean, default: true
  attr :on_save_override, :string, default: nil
  attr :on_confirm_fork, :string, required: true
  attr :on_cancel, :string, required: true

  def pack_fork_confirmation_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      id={@id}
      data-role="pack-fork-confirmation-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
    >
      <div class="w-full max-w-lg rounded-xl border border-sr-line bg-sr-surface p-6 shadow-sr-raised">
        <div class="flex items-start gap-3">
          <div class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-amber-500/15 text-amber-600 dark:text-amber-400">
            <.icon name="hero-exclamation-triangle" class="size-5" />
          </div>
          <div class="min-w-0 flex-1">
            <h3 id={"#{@id}-title"} class="text-base font-semibold text-sr-ink">
              Structural edit on managed {@resource_label}
            </h3>
            <p class="mt-1 text-sm text-sr-muted">
              This {@resource_label} is managed by Solution Pack
              <span class="font-mono font-medium text-sr-ink">{@pack_id}</span>
              <span :if={@pack_version}>(v{@pack_version})</span>.
              Structural changes diverge from the upstream pack template.
            </p>
          </div>
        </div>

        <div class="mt-4 rounded-lg border border-sr-line bg-sr-subtle p-3 text-xs text-sr-muted space-y-1">
          <p>
            <strong class="text-sr-ink">Detach / Fork (managed: false):</strong>
            Saves your structural edits and detaches from automatic pack upgrades so future upgrades never overwrite your changes.
          </p>
          <p :if={@allow_override_save and is_binary(@on_save_override)}>
            <strong class="text-sr-ink">Save Parameter Override:</strong>
            Keeps <code class="font-mono">managed: true</code>
            and saves only threshold/cooldown/enabled overrides.
          </p>
        </div>

        <div class="mt-6 flex flex-wrap items-center justify-end gap-2">
          <.ui_button type="button" variant="ghost" size="sm" phx-click={@on_cancel}>
            Cancel
          </.ui_button>
          <.ui_button
            :if={@allow_override_save and is_binary(@on_save_override)}
            type="button"
            variant="outline"
            size="sm"
            phx-click={@on_save_override}
          >
            Save Parameter Override
          </.ui_button>
          <.ui_button
            type="button"
            variant="primary"
            size="sm"
            phx-click={@on_confirm_fork}
          >
            Detach / Fork (managed: false)
          </.ui_button>
        </div>
      </div>
    </div>
    """
  end
end
