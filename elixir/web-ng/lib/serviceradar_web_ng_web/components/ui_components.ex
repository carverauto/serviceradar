defmodule ServiceRadarWebNGWeb.UIComponents do
  @moduledoc """
  App-level UI primitives built on Tailwind + shared ServiceRadar (`sr-*`) tokens.

  Keep these components small and composable so feature templates stay free of
  daisyUI class soup. Prefer these over raw `btn` / `input` / `badge` / `table` classes.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  attr :variant, :string,
    default: "primary",
    values: ~w(primary ghost soft neutral outline danger warning info success)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :square, :boolean, default: false
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(
      href navigate patch method download name value type disabled form
      target rel replace
      phx-click phx-target phx-value-idx phx-value-id phx-value-entity phx-value-group_id phx-value-metric
      phx-value-q phx-value-type phx-value-favorite phx-value-field phx-value-value
      phx-value-state phx-value-severity phx-value-mode phx-value-cursor phx-value-page
      phx-value-addon_id phx-value-version phx-value-release_tag phx-value-replace
      phx-confirm data-confirm
      aria-label aria-controls aria-expanded title
    )

  slot :inner_block, required: true

  def ui_button(%{rest: rest} = assigns) do
    link_target = rest[:href] || rest[:navigate] || rest[:patch]

    assigns =
      assigns
      |> assign(:computed_class, ui_button_class(assigns))
      |> assign(:link?, link_target != nil)

    ~H"""
    <.link :if={@link?} class={@computed_class} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <button :if={not @link?} class={@computed_class} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :variant, :string,
    default: "ghost",
    values: ~w(primary ghost soft neutral outline danger warning info success)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(
      href navigate patch method download name value type disabled form
      target rel
      phx-click phx-target phx-value-idx phx-value-id phx-value-entity phx-value-group_id phx-value-metric
      phx-value-q phx-value-type phx-value-favorite phx-value-field phx-value-value
      phx-value-state phx-value-severity phx-value-mode phx-value-cursor phx-value-page
      phx-value-addon_id phx-value-version phx-value-release_tag phx-value-replace
      phx-value-reset
      phx-confirm data-confirm
      aria-label aria-controls aria-expanded title
    )

  slot :inner_block, required: true

  def ui_icon_button(assigns) do
    assigns =
      assigns
      |> assign(:rest, Map.put_new(assigns.rest, :type, "button"))
      |> assign(:square, true)

    ~H"""
    <.ui_button
      variant={@variant}
      size={@size}
      square={@square}
      active={@active}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.ui_button>
    """
  end

  attr :variant, :string, default: "bordered", values: ~w(bordered ghost)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(
      name value type placeholder autocomplete disabled form min max step inputmode
      phx-debounce phx-throttle
    )

  def ui_input(assigns) do
    assigns = assign(assigns, :computed_class, ui_input_class(assigns))

    ~H"""
    <input class={@computed_class} {@rest} />
    """
  end

  attr :class, :any, default: nil
  attr :rule_id, :any, default: nil

  attr :rest, :global, include: ~w(name value form disabled phx-change phx-target phx-debounce phx-throttle)

  slot :inner_block, required: true

  def ui_inline_select(assigns) do
    ~H"""
    <select
      class={["bg-transparent text-sm font-medium outline-none disabled:opacity-60", @class]}
      phx-value-id={@rule_id}
      {@rest}
    >
      {render_slot(@inner_block)}
    </select>
    """
  end

  attr :class, :any, default: nil
  attr :rule_id, :any, default: nil

  attr :rest, :global, include: ~w(name value form type placeholder disabled min max step phx-change phx-blur phx-target
                phx-debounce phx-throttle)

  def ui_inline_input(assigns) do
    ~H"""
    <input
      class={["bg-transparent text-sm font-medium outline-none disabled:opacity-60", @class]}
      phx-value-id={@rule_id}
      {@rest}
    />
    """
  end

  attr :variant, :string,
    default: "ghost",
    values: ~w(ghost warning success error info outline primary)

  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-uid title data-tip data-role)

  slot :inner_block, required: true

  def ui_badge(assigns) do
    assigns = assign(assigns, :computed_class, ui_badge_class(assigns))

    ~H"""
    <span class={@computed_class} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Map common daisy-style status/severity tokens to `ui_badge` variants.
  """
  def badge_variant_for(nil), do: "ghost"
  def badge_variant_for(""), do: "ghost"

  def badge_variant_for(value) when is_atom(value), do: value |> Atom.to_string() |> badge_variant_for()

  def badge_variant_for(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      v when v in ~w(critical fatal error failed down danger destructive) -> "error"
      v when v in ~w(high warning warn degraded pending at_risk) -> "warning"
      v when v in ~w(success ok up healthy attributed low resolved) -> "success"
      v when v in ~w(info medium running active primary) -> "info"
      v when v in ~w(outline) -> "outline"
      _ -> "ghost"
    end
  end

  def badge_variant_for(_), do: "ghost"

  attr :class, :any, default: nil
  slot :left
  slot :right
  slot :inner_block

  def ui_toolbar(assigns) do
    ~H"""
    <div class={["flex items-center justify-between gap-3", @class]}>
      <div class="flex min-w-0 items-center gap-2">
        {render_slot(@left)}
        {render_slot(@inner_block)}
      </div>
      <div class="flex shrink-0 items-center gap-2">
        {render_slot(@right)}
      </div>
    </div>
    """
  end

  attr :tabs, :list, required: true
  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :any, default: nil

  def ui_tabs(assigns) do
    ~H"""
    <nav class={["flex items-center gap-1", @class]}>
      <%= for tab <- @tabs do %>
        <.ui_button
          size={@size}
          variant={Map.get(tab, :variant, "ghost")}
          active={Map.get(tab, :active, false)}
          href={Map.get(tab, :href)}
          patch={Map.get(tab, :patch)}
          navigate={Map.get(tab, :navigate)}
        >
          {Map.get(tab, :label)}
        </.ui_button>
      <% end %>
    </nav>
    """
  end

  attr :align, :string, default: "end", values: ~w(start end)
  attr :placement, :string, default: "bottom", values: ~w(bottom top)
  attr :class, :any, default: nil
  attr :menu_class, :any, default: nil
  attr :aria_label, :string, default: nil
  slot :trigger, required: true
  slot :item, required: true

  def ui_dropdown(assigns) do
    ~H"""
    <%!--
      Native <details> menu. Trigger content is pointer-events-none so a nested
      <button> (ui_icon_button) cannot steal the summary activation click.
      Menu uses fixed z-index + open-state elevation so it escapes clipped
      table/panel ancestors (overflow-x-auto / rounded panels).
    --%>
    <details class={["sr-ui-dropdown group relative inline-block text-left", @class]}>
      <summary
        class="sr-ui-dropdown-trigger list-none cursor-pointer outline-none focus-visible:ring-2 focus-visible:ring-sr-focus [&::-webkit-details-marker]:hidden"
        aria-label={@aria_label}
      >
        <span class="pointer-events-none inline-flex items-center">
          {render_slot(@trigger)}
        </span>
      </summary>
      <ul
        class={[
          "sr-ui-dropdown-menu absolute z-[var(--sr-z-menu)] grid min-w-44 w-max max-w-64 gap-0.5 rounded-sr-surface border border-sr-line bg-sr-raised p-1.5 shadow-sr-raised",
          @placement == "bottom" && "top-full mt-1.5",
          @placement == "top" && "bottom-full mb-1.5",
          @align == "end" && "right-0 origin-top-right",
          @align == "start" && "left-0 origin-top-left",
          @menu_class
        ]}
        role="menu"
      >
        <%= for item <- @item do %>
          <li class="min-w-0 [&>a]:flex [&>a]:items-center [&>a]:gap-2 [&>a]:rounded-sr-control [&>a]:px-3 [&>a]:py-2 [&>a]:text-sm [&>a]:text-sr-ink [&>a]:outline-none [&>a]:hover:bg-sr-subtle [&>a]:focus-visible:ring-2 [&>a]:focus-visible:ring-sr-focus [&>button]:flex [&>button]:w-full [&>button]:items-center [&>button]:gap-2 [&>button]:rounded-sr-control [&>button]:px-3 [&>button]:py-2 [&>button]:text-left [&>button]:text-sm [&>button]:text-sr-ink [&>button]:outline-none [&>button]:hover:bg-sr-subtle [&>span]:flex [&>span]:w-full [&>span]:items-center [&>span]:gap-2 [&>span]:rounded-sr-control [&>span]:px-3 [&>span]:py-2 [&>span]:text-sm [&>span]:text-sr-muted">
            {render_slot(item)}
          </li>
        <% end %>
      </ul>
    </details>
    """
  end

  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :header_class, :any, default: nil
  attr :body_class, :any, default: nil

  slot :header
  slot :inner_block, required: true

  def ui_panel(assigns) do
    ~H"""
    <%!--
      No overflow-hidden on the section: it clips absolute menus (row ⋮ actions).
      Radius still clips painted backgrounds via border-radius + background.
    --%>
    <section
      id={@id}
      class={[
        "relative rounded-sr-surface border border-sr-line bg-sr-surface shadow-sr-surface",
        @class
      ]}
    >
      <header
        :if={@header != []}
        class={[
          "flex items-start justify-between gap-3 rounded-t-sr-surface border-b border-sr-line bg-sr-subtle/60 px-4 py-3",
          @header_class
        ]}
      >
        {render_slot(@header)}
      </header>
      <div class={["px-4 py-4", @body_class]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp ui_button_class(assigns) do
    [
      ui_button_base(),
      ui_button_variant_class(assigns.variant),
      ui_button_size_class(assigns.size),
      assigns.square && ui_button_square_class(assigns.size),
      assigns.active && ui_button_active_class(),
      assigns.class
    ]
  end

  defp ui_button_base do
    "inline-flex items-center justify-center gap-1.5 whitespace-nowrap font-sans font-semibold tracking-tight outline-none transition-[transform,background-color,border-color,color,box-shadow] duration-200 ease-sr-out focus-visible:ring-2 focus-visible:ring-sr-focus focus-visible:ring-offset-2 focus-visible:ring-offset-sr-canvas disabled:pointer-events-none disabled:opacity-50 active:translate-y-px"
  end

  defp ui_button_variant_class("primary") do
    "rounded-sr-control border border-transparent bg-sr-brand text-sr-on-brand shadow-sr-button hover:bg-sr-brand-strong"
  end

  defp ui_button_variant_class("soft") do
    "rounded-sr-control border border-sr-line bg-sr-subtle text-sr-brand shadow-sr-control hover:border-sr-line-hover hover:bg-sr-control"
  end

  defp ui_button_variant_class("neutral") do
    "rounded-sr-control border border-sr-line bg-sr-control text-sr-ink shadow-sr-control hover:border-sr-line-hover hover:bg-sr-subtle"
  end

  defp ui_button_variant_class("outline") do
    "rounded-sr-control border border-sr-line-strong bg-transparent text-sr-ink hover:border-sr-line-hover hover:bg-sr-subtle"
  end

  defp ui_button_variant_class("ghost") do
    "rounded-sr-control border border-transparent bg-transparent text-sr-muted hover:bg-sr-subtle hover:text-sr-ink"
  end

  defp ui_button_variant_class("danger") do
    "rounded-sr-control border border-red-500/40 bg-red-500/15 text-red-700 hover:bg-red-500/20 dark:border-red-400/45 dark:bg-red-500/15 dark:text-red-300"
  end

  defp ui_button_variant_class("warning") do
    "rounded-sr-control border border-amber-500/30 bg-amber-500/10 text-amber-800 hover:bg-amber-500/15 dark:text-amber-300"
  end

  defp ui_button_variant_class("info") do
    "rounded-sr-control border border-sr-brand/30 bg-sr-brand/10 text-sr-brand-strong hover:bg-sr-brand/15 dark:text-sr-brand"
  end

  defp ui_button_variant_class("success") do
    "rounded-sr-control border border-emerald-500/35 bg-emerald-500/15 text-emerald-800 hover:bg-emerald-500/20 dark:border-emerald-400/40 dark:bg-emerald-500/15 dark:text-emerald-300"
  end

  defp ui_button_variant_class(_), do: ui_button_variant_class("primary")

  defp ui_button_size_class("xs"), do: "min-h-7 px-2 text-xs"
  defp ui_button_size_class("sm"), do: "min-h-9 px-3 text-sm"
  defp ui_button_size_class("md"), do: "min-h-11 px-3.5 text-sm"
  defp ui_button_size_class("lg"), do: "min-h-12 px-4 text-base"
  defp ui_button_size_class(_), do: ui_button_size_class("sm")

  defp ui_button_square_class("xs"), do: "size-7 min-h-7 px-0"
  defp ui_button_square_class("sm"), do: "size-9 min-h-9 px-0"
  defp ui_button_square_class("md"), do: "size-11 min-h-11 px-0"
  defp ui_button_square_class("lg"), do: "size-12 min-h-12 px-0"
  defp ui_button_square_class(_), do: ui_button_square_class("sm")

  defp ui_button_active_class do
    "ring-2 ring-sr-brand/40 ring-offset-1 ring-offset-sr-canvas"
  end

  defp ui_input_class(assigns) do
    [
      ui_input_base(),
      ui_input_variant_class(assigns.variant),
      ui_input_size_class(assigns.size),
      assigns.mono && "font-mono",
      assigns.class
    ]
  end

  defp ui_input_base do
    "w-full rounded-sr-control border bg-sr-control text-sr-ink outline-none transition-[border-color,box-shadow,background-color] duration-200 ease-sr-out placeholder:text-sr-muted focus-visible:border-sr-line-hover focus-visible:ring-2 focus-visible:ring-sr-focus disabled:cursor-not-allowed disabled:opacity-60"
  end

  defp ui_input_variant_class("ghost") do
    "border-transparent bg-transparent shadow-none hover:bg-sr-subtle focus-visible:bg-sr-control"
  end

  defp ui_input_variant_class(_) do
    "border-sr-line shadow-sr-control"
  end

  defp ui_input_size_class("xs"), do: "min-h-7 px-2 text-xs"
  defp ui_input_size_class("sm"), do: "min-h-9 px-3 text-sm"
  defp ui_input_size_class("md"), do: "min-h-11 px-3.5 text-sm"
  defp ui_input_size_class("lg"), do: "min-h-12 px-4 text-base"
  defp ui_input_size_class(_), do: ui_input_size_class("sm")

  defp ui_badge_class(assigns) do
    [
      "inline-flex items-center justify-center gap-1 whitespace-nowrap rounded-full border font-sans font-semibold tracking-wide",
      ui_badge_variant_class(assigns.variant),
      ui_badge_size_class(assigns.size),
      assigns.class
    ]
  end

  defp ui_badge_variant_class("warning") do
    "border-amber-500/30 bg-amber-500/10 text-amber-700 dark:text-amber-300"
  end

  defp ui_badge_variant_class("success") do
    "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
  end

  defp ui_badge_variant_class("error") do
    "border-red-500/40 bg-red-500/15 text-red-700 dark:border-red-400/45 dark:bg-red-500/15 dark:text-red-300"
  end

  defp ui_badge_variant_class("info") do
    "border-sr-brand/30 bg-sr-brand/10 text-sr-brand-strong dark:border-sr-brand/40 dark:bg-sr-brand/12 dark:text-sr-brand"
  end

  defp ui_badge_variant_class("outline") do
    "border-sr-line-strong bg-transparent text-sr-ink"
  end

  defp ui_badge_variant_class("primary") do
    "border-sr-brand/40 bg-sr-brand/15 text-sr-brand-strong dark:text-sr-brand"
  end

  defp ui_badge_variant_class(_) do
    "border-sr-line bg-sr-subtle text-sr-muted"
  end

  defp ui_badge_size_class("xs"), do: "min-h-5 px-1.5 text-[0.65rem]"
  defp ui_badge_size_class("sm"), do: "min-h-6 px-2 text-xs"
  defp ui_badge_size_class("md"), do: "min-h-7 px-2.5 text-sm"
  defp ui_badge_size_class(_), do: ui_badge_size_class("sm")

  @doc """
  Brand data-table class list. Prefer over daisy `table table-sm table-zebra`.

  ## Options

    * `:size` - `"xs" | "sm" | "md"` (default `"sm"`)
    * `:zebra` - striped rows (default `false`)
    * `:fixed` - `table-layout: fixed` (default `false`)
    * `:class` - extra classes

  ## Example

      <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
  """
  def ui_table_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "sm") |> to_string()
    zebra? = Keyword.get(opts, :zebra, false) in [true, "true"]
    fixed? = Keyword.get(opts, :fixed, false) in [true, "true"]
    extra = Keyword.get(opts, :class)

    [
      "sr-ui-table",
      ui_table_size_class(size),
      zebra? && "sr-ui-table-zebra",
      fixed? && "sr-ui-table-fixed",
      extra
    ]
  end

  defp ui_table_size_class("xs"), do: "sr-ui-table-xs"
  defp ui_table_size_class("md"), do: "sr-ui-table-md"
  defp ui_table_size_class(_), do: "sr-ui-table-sm"

  @doc """
  Brand field classes for raw `<input>` / `<select>` / `<textarea>` outside `<.input>`.

  Prefer `<.input>` when binding to a form field. Use this helper for ad-hoc controls.

  ## Options

    * `:size` - `"xs" | "sm" | "md"` (default `"md"`)
    * `:mono` - monospace (default `false`)
    * `:class` - extra classes
  """
  def ui_field_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "md") |> to_string()
    mono? = Keyword.get(opts, :mono, false) in [true, "true"]
    extra = Keyword.get(opts, :class)

    [
      "w-full rounded-sr-control border border-sr-line bg-sr-control text-sr-ink shadow-sr-control outline-none transition-[border-color,box-shadow] duration-200 ease-sr-out placeholder:text-sr-muted focus-visible:border-sr-line-hover focus-visible:ring-2 focus-visible:ring-sr-focus disabled:cursor-not-allowed disabled:opacity-60",
      ui_field_size_class(size),
      mono? && "font-mono",
      extra
    ]
  end

  defp ui_field_size_class("xs"), do: "min-h-7 px-2 text-xs"
  defp ui_field_size_class("sm"), do: "min-h-9 px-3 text-sm"
  defp ui_field_size_class(_), do: "min-h-11 px-3.5 text-sm"

  @doc """
  Brand alert surface class list. Prefer over daisy `alert alert-*`.

  Accepts a variant string (`"error"`) or keyword options:

    * `:variant` - `"info" | "warning" | "error" | "success" | "ghost"` (default `"info"`)
    * `:class` - extra classes
  """
  def ui_alert_class(opts \\ [])

  def ui_alert_class(variant) when is_binary(variant) or is_atom(variant) do
    ui_alert_class(variant: variant)
  end

  def ui_alert_class(opts) when is_list(opts) do
    variant = opts |> Keyword.get(:variant, "info") |> to_string()
    extra = Keyword.get(opts, :class)

    [
      "flex items-start gap-3 rounded-sr-surface border px-4 py-3 text-sm leading-snug",
      ui_alert_variant_class(variant),
      extra
    ]
  end

  defp ui_alert_variant_class("error") do
    "border-red-500/40 bg-red-500/12 text-red-800 dark:text-red-200"
  end

  defp ui_alert_variant_class("warning") do
    "border-amber-500/35 bg-amber-500/12 text-amber-900 dark:text-amber-200"
  end

  defp ui_alert_variant_class("success") do
    "border-emerald-500/35 bg-emerald-500/12 text-emerald-900 dark:text-emerald-200"
  end

  defp ui_alert_variant_class("ghost") do
    "border-sr-line bg-sr-subtle text-sr-ink"
  end

  defp ui_alert_variant_class(_) do
    "border-sr-brand/35 bg-sr-brand/12 text-sr-brand-strong dark:text-sr-brand"
  end

  attr :variant, :string,
    default: "info",
    values: ~w(info warning error success ghost)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def ui_alert(assigns) do
    assigns =
      assign(assigns, :computed_class, ui_alert_class(variant: assigns.variant, class: assigns.class))

    ~H"""
    <div role="alert" class={@computed_class} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  attr :id, :string, required: true
  attr :open, :boolean, default: true
  attr :size, :string, default: "md", values: ~w(sm form md lg xl 2xl 6xl)
  attr :class, :any, default: nil
  attr :box_class, :any, default: nil
  attr :on_cancel, :any, default: nil
  attr :on_cancel_target, :any, default: nil
  attr :show_close, :boolean, default: true
  attr :rest, :global
  slot :title
  slot :actions
  slot :inner_block, required: true

  def ui_modal(assigns) do
    ~H"""
    <%!--
      Native <dialog> + DialogTopLayer (showModal) escapes ops-shell stacking
      (sidebar z-index + .sr-ops-content isolation) so overlays always win.
    --%>
    <dialog
      :if={@open}
      id={@id}
      class={["sr-ui-modal sr-ui-modal-open", @class]}
      phx-hook="DialogTopLayer"
      data-cancel={@on_cancel}
      data-cancel-target={@on_cancel_target}
      aria-labelledby={if @title != [], do: "#{@id}-title"}
      {@rest}
    >
      <div class={[
        "sr-ui-modal-box relative border border-sr-line bg-sr-surface text-sr-ink shadow-sr-raised",
        ui_modal_size_class(@size),
        @box_class
      ]}>
        <.ui_icon_button
          :if={@show_close && @on_cancel}
          type="button"
          size="sm"
          variant="ghost"
          class="absolute right-2 top-2 z-10"
          phx-click={@on_cancel}
          phx-target={@on_cancel_target}
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.ui_icon_button>
        <div :if={@title != []} class="mb-3 flex items-start justify-between gap-3 pr-8">
          <h3 id={"#{@id}-title"} class="text-lg font-semibold tracking-tight text-sr-ink">
            {render_slot(@title)}
          </h3>
        </div>
        <div class="space-y-3">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="sr-ui-modal-action">{render_slot(@actions)}</div>
      </div>
    </dialog>
    """
  end

  # Map to CSS tokens that set max-width (and width for larger sizes).
  # Do not rely on Tailwind max-w-* alone — older .sr-ui-modal-box rules
  # hard-locked width and silently ignored max-w utilities.
  defp ui_modal_size_class("sm"), do: "sr-ui-modal-box-sm"
  defp ui_modal_size_class("form"), do: "sr-ui-modal-box-form"
  defp ui_modal_size_class("md"), do: "sr-ui-modal-box-md"
  defp ui_modal_size_class("lg"), do: "sr-ui-modal-box-lg"
  defp ui_modal_size_class("xl"), do: "sr-ui-modal-box-xl"
  defp ui_modal_size_class("2xl"), do: "sr-ui-modal-box-xl"
  defp ui_modal_size_class("6xl"), do: "sr-ui-modal-box-2xl"
  defp ui_modal_size_class(_), do: "sr-ui-modal-box-md"

  @doc """
  Brand class list for daisy `join` input+button clusters.
  """
  def ui_join_class(opts \\ []) when is_list(opts) do
    extra = Keyword.get(opts, :class)

    [
      "inline-flex w-full items-stretch align-middle [&>*:not(:first-child)]:ms-[-1px] [&>*:first-child]:rounded-e-none [&>*:last-child]:rounded-s-none [&>*:not(:first-child):not(:last-child)]:rounded-none",
      extra
    ]
  end

  @doc """
  Brand checkbox classes (prefer over `checkbox checkbox-*`).
  """
  def ui_checkbox_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "sm") |> to_string()
    extra = Keyword.get(opts, :class)

    [
      "sr-ui-checkbox rounded border-sr-line-strong text-sr-brand accent-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus",
      ui_checkbox_size_class(size),
      extra
    ]
  end

  defp ui_checkbox_size_class("xs"), do: "size-3.5"
  defp ui_checkbox_size_class("md"), do: "size-5"
  defp ui_checkbox_size_class(_), do: "size-4"

  @doc """
  Brand switch/toggle classes (prefer over daisy `toggle toggle-*`).

  ## Options

    * `:size` - `"sm" | "md"` (default `"md"`)
    * `:class` - extra classes
  """
  def ui_toggle_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "md") |> to_string()
    extra = Keyword.get(opts, :class)

    [
      "sr-ui-toggle",
      size == "sm" && "sr-ui-toggle-sm",
      extra
    ]
  end

  @doc """
  Brand loading spinner. Prefer over daisy `loading loading-spinner`.
  """
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :class, :any, default: nil
  attr :rest, :global

  def ui_spinner(assigns) do
    ~H"""
    <span
      class={["sr-ui-spinner", ui_spinner_size_class(@size), @class]}
      aria-hidden="true"
      {@rest}
    ></span>
    """
  end

  defp ui_spinner_size_class("xs"), do: "sr-ui-spinner-xs"
  defp ui_spinner_size_class("md"), do: "sr-ui-spinner-md"
  defp ui_spinner_size_class("lg"), do: "sr-ui-spinner-lg"
  defp ui_spinner_size_class(_), do: "sr-ui-spinner-sm"

  @doc """
  Cursor-based pagination component for SRQL-driven pages.

  Uses token-styled `ui_button` chrome. Supports page indicators when total_count is provided.

  ## Session position (modern)

  Page changes fire `phx-click={@event}` (default `"srql_paginate"`) with
  `phx-value-cursor` / `phx-value-page`. LiveViews handle the event via
  `SRQL.Page.paginate/3` so keyset cursors stay in assigns — not the shareable URL.

  Limit is never encoded in the URL; it lives in SRQL (`limit:N`) or the LiveView default.

  `base_path`, `query`, and `extra_params` remain for call-site compatibility but
  are no longer written into navigation hrefs.
  """
  attr :prev_cursor, :string, default: nil
  attr :next_cursor, :string, default: nil
  attr :base_path, :string, default: "/"
  attr :query, :string, default: ""
  attr :limit, :integer, default: 20
  attr :result_count, :integer, default: 0
  attr :total_count, :integer, default: nil
  attr :current_page, :integer, default: 1
  attr :extra_params, :map, default: %{}
  attr :event, :string, default: "srql_paginate"
  attr :class, :any, default: nil

  def ui_pagination(assigns) do
    has_prev = is_binary(assigns.prev_cursor) and assigns.prev_cursor != ""
    has_next = is_binary(assigns.next_cursor) and assigns.next_cursor != ""
    total_pages = calculate_total_pages(assigns.total_count, assigns.limit)

    assigns =
      assigns
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)
      |> assign(:total_pages, total_pages)
      |> assign(
        :showing_text,
        pagination_text(assigns.result_count, assigns.limit, assigns.total_count)
      )

    ~H"""
    <div class={["flex flex-wrap items-center justify-between gap-4", @class]}>
      <div class="flex items-center gap-3">
        <span class="text-sm text-sr-muted">
          {@showing_text}
        </span>
        <span :if={@total_pages && @total_pages > 1} class="text-xs text-sr-muted/80">
          Page {@current_page} of {@total_pages}
        </span>
      </div>
      <div class="flex items-center gap-1">
        <.ui_button
          :if={@current_page > 1}
          type="button"
          variant="outline"
          size="sm"
          phx-click={@event}
          phx-value-page="1"
          title="First page"
          aria-label="First page"
        >
          <.icon name="hero-chevron-double-left" class="size-4" />
        </.ui_button>

        <.ui_button
          :if={@has_prev}
          type="button"
          variant="outline"
          size="sm"
          phx-click={@event}
          phx-value-cursor={@prev_cursor}
          phx-value-page={to_string(max(@current_page - 1, 1))}
        >
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.ui_button>
        <.ui_button :if={not @has_prev} variant="outline" size="sm" disabled type="button">
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.ui_button>

        <span
          :if={@total_pages && @total_pages > 1}
          class="inline-flex min-h-9 items-center px-2 text-sm text-sr-muted"
        >
          {@current_page} / {@total_pages}
        </span>

        <.ui_button
          :if={@has_next}
          type="button"
          variant="outline"
          size="sm"
          phx-click={@event}
          phx-value-cursor={@next_cursor}
          phx-value-page={to_string(@current_page + 1)}
        >
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.ui_button>
        <.ui_button :if={not @has_next} variant="outline" size="sm" disabled type="button">
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.ui_button>
      </div>
    </div>
    """
  end

  defp calculate_total_pages(nil, _limit), do: nil

  defp calculate_total_pages(total, limit) when is_integer(total) and total > 0 and is_integer(limit) and limit > 0 do
    ceil(total / limit)
  end

  defp calculate_total_pages(_, _), do: nil

  defp pagination_text(count, _limit, total) when is_integer(count) and count > 0 and is_integer(total) and total > 0 do
    "Showing #{count} of #{format_number(total)} result#{if total == 1, do: "", else: "s"}"
  end

  defp pagination_text(count, _limit, _total) when is_integer(count) and count > 0 do
    "Showing #{count} result#{if count == 1, do: "", else: "s"}"
  end

  defp pagination_text(_, _, _), do: "No results"

  defp format_number(n) when is_integer(n) and n >= 1000 do
    n
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: Integer.to_string(n)
end
