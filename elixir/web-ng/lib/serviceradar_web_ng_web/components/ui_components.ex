defmodule ServiceRadarWebNGWeb.UIComponents do
  @moduledoc """
  App-level UI primitives.

  Shared buttons, badges, panels, alerts, dropdowns, modals, spinners, and
  the table/field class lists delegate to `ServiceRadarUI`. These `ui_*`
  names are the one-release wrappers. Toolbar, inline controls, tabs, cursor
  pagination, and the join/checkbox/toggle class helpers stay here because
  the package does not express them.
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  alias ServiceRadarUI.Components, as: UI

  @button_link_attrs ~w(href navigate patch method download replace name value type disabled form target rel)

  attr :variant, :string,
    default: "primary",
    values: ~w(primary ghost soft neutral outline danger warning info success)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :square, :boolean, default: false
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: @button_link_attrs
  slot :inner_block, required: true

  def ui_button(assigns) do
    ~H"""
    <UI.button
      variant={@variant}
      size={@size}
      square={@square}
      active={@active}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </UI.button>
    """
  end

  attr :variant, :string,
    default: "ghost",
    values: ~w(primary ghost soft neutral outline danger warning info success)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: @button_link_attrs
  slot :inner_block, required: true

  def ui_icon_button(assigns) do
    ~H"""
    <UI.icon_button variant={@variant} size={@size} active={@active} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </UI.icon_button>
    """
  end

  attr :variant, :string, default: "bordered", values: ~w(bordered ghost)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(name value type placeholder autocomplete disabled form min max step inputmode phx-debounce phx-throttle)

  def ui_input(assigns) do
    ~H"""
    <input
      class={UI.control_class(variant: @variant, size: @size, mono: @mono, class: @class)}
      {@rest}
    />
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

  attr :rest, :global,
    include:
      ~w(name value form type placeholder disabled min max step phx-change phx-blur phx-target phx-debounce phx-throttle)

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
    ~H"""
    <UI.badge variant={@variant} size={@size} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </UI.badge>
    """
  end

  @doc """
  Map common status and severity words to `ui_badge` variants.

  Keeps the product vocabulary: `attributed` is success, and the word
  `primary` is info.
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
    <UI.dropdown
      label={@aria_label}
      align={@align}
      placement={@placement}
      class={@class}
      menu_class={@menu_class}
    >
      <:trigger>{render_slot(@trigger)}</:trigger>
      <:item :for={item <- @item}>{render_slot(item)}</:item>
    </UI.dropdown>
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
    <UI.panel
      id={@id}
      class={@class}
      header_class={@header_class}
      body_class={@body_class}
    >
      <:header :if={@header != []}>{render_slot(@header)}</:header>
      {render_slot(@inner_block)}
    </UI.panel>
    """
  end

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
  def ui_table_class(opts \\ []) when is_list(opts), do: UI.table_class(opts)

  @doc """
  Brand field classes for raw `<input>` / `<select>` / `<textarea>` outside `<.input>`.

  Prefer `<.input>` when binding to a form field. Use this helper for ad-hoc controls.

  ## Options

    * `:size` - `"xs" | "sm" | "md"` (default `"md"`)
    * `:mono` - monospace (default `false`)
    * `:class` - extra classes
  """
  def ui_field_class(opts \\ []) when is_list(opts) do
    UI.control_class(
      size: Keyword.get(opts, :size, "md"),
      mono: Keyword.get(opts, :mono, false),
      class: Keyword.get(opts, :class)
    )
  end

  @doc """
  Brand alert surface class list.

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

    variant =
      if variant in ~w(info success warning error ghost), do: variant, else: "info"

    ["sr-ui-alert", "sr-ui-alert-#{variant}", Keyword.get(opts, :class)]
  end

  attr :variant, :string,
    default: "info",
    values: ~w(info warning error success ghost)

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def ui_alert(assigns) do
    ~H"""
    <UI.alert variant={@variant} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </UI.alert>
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
    {package_size, extra_box} = modal_package_size(assigns.size)

    assigns =
      assigns
      |> assign(:package_size, package_size)
      |> assign(:extra_box, extra_box)

    ~H"""
    <UI.modal
      :if={@open}
      id={@id}
      size={@package_size}
      hook="DialogTopLayer"
      class={@class}
      box_class={[@extra_box, @box_class]}
      on_cancel={@on_cancel}
      on_cancel_target={@on_cancel_target}
      show_close={@show_close}
      {@rest}
    >
      <:title :if={@title != []}>{render_slot(@title)}</:title>
      {render_slot(@inner_block)}
      <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
    </UI.modal>
    """
  end

  # Package sizes are sm/md/lg/xl/2xl. `form` keeps the app width class.
  # `2xl` historically used the xl box; `6xl` used the 2xl box.
  defp modal_package_size("form"), do: {"md", "sr-ui-modal-box-form"}
  defp modal_package_size("6xl"), do: {"2xl", nil}
  defp modal_package_size("2xl"), do: {"xl", nil}
  defp modal_package_size(size) when size in ~w(sm md lg xl), do: {size, nil}
  defp modal_package_size(_size), do: {"md", nil}

  @doc """
  Brand class list for daisy `join` input+button clusters.
  """
  def ui_join_class(opts \\ []) when is_list(opts) do
    [
      "inline-flex w-full items-stretch align-middle [&>*:not(:first-child)]:ms-[-1px] [&>*:first-child]:rounded-e-none [&>*:last-child]:rounded-s-none [&>*:not(:first-child):not(:last-child)]:rounded-none",
      Keyword.get(opts, :class)
    ]
  end

  @doc """
  Brand checkbox classes (prefer over `checkbox checkbox-*`).
  """
  def ui_checkbox_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "sm") |> to_string()

    [
      "sr-ui-checkbox rounded border-sr-line-strong text-sr-brand accent-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus",
      checkbox_size_class(size),
      Keyword.get(opts, :class)
    ]
  end

  defp checkbox_size_class("xs"), do: "size-3.5"
  defp checkbox_size_class("md"), do: "size-5"
  defp checkbox_size_class(_size), do: "size-4"

  @doc """
  Brand switch/toggle classes (prefer over daisy `toggle toggle-*`).

  ## Options

    * `:size` - `"sm" | "md"` (default `"md"`)
    * `:class` - extra classes
  """
  def ui_toggle_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "md") |> to_string()

    [
      "sr-ui-toggle",
      size == "sm" && "sr-ui-toggle-sm",
      Keyword.get(opts, :class)
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
    <UI.spinner size={@size} class={@class} {@rest} />
    """
  end

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
