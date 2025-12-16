defmodule ServiceRadarWebNGWeb.UIComponents do
  @moduledoc """
  App-level UI primitives built on Tailwind + daisyUI.

  Keep these components small and composable so we can swap/adjust styling
  without touching feature templates.
  """

  use Phoenix.Component
  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  attr :variant, :string,
    default: "primary",
    values: ~w(primary ghost soft neutral outline)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :square, :boolean, default: false
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(
      href navigate patch method download name value type disabled form
      phx-click phx-value-idx phx-value-id phx-value-entity
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
    values: ~w(primary ghost soft neutral outline)

  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(
      href navigate patch method download name value type disabled form
      phx-click phx-value-idx phx-value-id phx-value-entity
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
  attr :rest, :global, include: ~w(name value disabled)

  slot :inner_block, required: true

  def ui_inline_select(assigns) do
    ~H"""
    <select
      class={["bg-transparent text-sm font-medium outline-none disabled:opacity-60", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </select>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(name value type placeholder disabled min max step)

  def ui_inline_input(assigns) do
    ~H"""
    <input
      class={["bg-transparent text-sm font-medium outline-none disabled:opacity-60", @class]}
      {@rest}
    />
    """
  end

  attr :variant, :string, default: "ghost", values: ~w(ghost warning success error info)
  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def ui_badge(assigns) do
    assigns = assign(assigns, :computed_class, ui_badge_class(assigns))

    ~H"""
    <span class={@computed_class} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  attr :class, :any, default: nil
  slot :left
  slot :right
  slot :inner_block

  def ui_toolbar(assigns) do
    ~H"""
    <div class={["flex items-center justify-between gap-3", @class]}>
      <div class="flex items-center gap-2 min-w-0">
        {render_slot(@left)}
        {render_slot(@inner_block)}
      </div>
      <div class="flex items-center gap-2 shrink-0">
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
  attr :class, :any, default: nil
  slot :trigger, required: true
  slot :item, required: true

  def ui_dropdown(assigns) do
    ~H"""
    <div class={[
      "dropdown",
      @align == "start" && "dropdown-start",
      @align == "end" && "dropdown-end",
      @class
    ]}>
      <div tabindex="0" role="button">
        {render_slot(@trigger)}
      </div>
      <ul
        tabindex="0"
        class="menu dropdown-content bg-base-100 rounded-box z-30 w-56 p-2 shadow border border-base-200 mt-2"
      >
        <%= for item <- @item do %>
          <li>{render_slot(item)}</li>
        <% end %>
      </ul>
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :header_class, :any, default: nil
  attr :body_class, :any, default: nil

  slot :header
  slot :inner_block, required: true

  def ui_panel(assigns) do
    ~H"""
    <section class={[
      "rounded-xl border border-base-200 bg-base-100 shadow-sm overflow-hidden",
      @class
    ]}>
      <header
        :if={@header != []}
        class={[
          "px-4 py-3 bg-base-200/40 flex items-start justify-between gap-3",
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
      "btn",
      ui_button_variant_class(assigns.variant),
      ui_button_size_class(assigns.size),
      assigns.square && "btn-square",
      assigns.active && "btn-active",
      assigns.class
    ]
  end

  defp ui_button_variant_class("primary"), do: "btn-primary"
  defp ui_button_variant_class("ghost"), do: "btn-ghost"
  defp ui_button_variant_class("neutral"), do: "btn-neutral"
  defp ui_button_variant_class("outline"), do: "btn-outline"
  defp ui_button_variant_class("soft"), do: "btn-primary btn-soft"
  defp ui_button_variant_class(_), do: "btn-primary"

  defp ui_button_size_class("xs"), do: "btn-xs"
  defp ui_button_size_class("sm"), do: "btn-sm"
  defp ui_button_size_class("md"), do: "btn-md"
  defp ui_button_size_class("lg"), do: "btn-lg"
  defp ui_button_size_class(_), do: "btn-sm"

  defp ui_input_class(assigns) do
    [
      "input",
      ui_input_variant_class(assigns.variant),
      ui_input_size_class(assigns.size),
      assigns.mono && "font-mono",
      assigns.class
    ]
  end

  defp ui_input_variant_class("ghost"), do: "input-ghost"
  defp ui_input_variant_class(_), do: "input-bordered"

  defp ui_input_size_class("xs"), do: "input-xs"
  defp ui_input_size_class("sm"), do: "input-sm"
  defp ui_input_size_class("md"), do: "input-md"
  defp ui_input_size_class("lg"), do: "input-lg"
  defp ui_input_size_class(_), do: "input-sm"

  defp ui_badge_class(assigns) do
    [
      "badge",
      ui_badge_variant_class(assigns.variant),
      ui_badge_size_class(assigns.size),
      assigns.class
    ]
  end

  defp ui_badge_variant_class("warning"), do: "badge-warning"
  defp ui_badge_variant_class("success"), do: "badge-success"
  defp ui_badge_variant_class("error"), do: "badge-error"
  defp ui_badge_variant_class("info"), do: "badge-info"
  defp ui_badge_variant_class(_), do: "badge-ghost"

  defp ui_badge_size_class("xs"), do: "badge-xs"
  defp ui_badge_size_class("sm"), do: "badge-sm"
  defp ui_badge_size_class("md"), do: "badge-md"
  defp ui_badge_size_class(_), do: "badge-sm"

  @doc """
  Cursor-based pagination component for SRQL-driven pages.

  Uses daisyUI join/button classes for styling.
  """
  attr :prev_cursor, :string, default: nil
  attr :next_cursor, :string, default: nil
  attr :base_path, :string, required: true
  attr :query, :string, default: ""
  attr :limit, :integer, default: 20
  attr :result_count, :integer, default: 0
  attr :extra_params, :map, default: %{}
  attr :class, :any, default: nil

  def ui_pagination(assigns) do
    assigns =
      assigns
      |> assign(:has_prev, is_binary(assigns.prev_cursor) and assigns.prev_cursor != "")
      |> assign(:has_next, is_binary(assigns.next_cursor) and assigns.next_cursor != "")
      |> assign(:showing_text, pagination_text(assigns.result_count, assigns.limit))

    ~H"""
    <div class={["flex items-center justify-between gap-4", @class]}>
      <div class="text-sm text-base-content/60">
        {@showing_text}
      </div>
      <div class="join">
        <.link
          :if={@has_prev}
          patch={pagination_href(@base_path, @query, @limit, @prev_cursor, @extra_params)}
          class="join-item btn btn-sm btn-outline"
        >
          <.icon name="hero-chevron-left" class="size-4" /> Previous
        </.link>
        <button :if={not @has_prev} class="join-item btn btn-sm btn-outline" disabled>
          <.icon name="hero-chevron-left" class="size-4" /> Previous
        </button>

        <.link
          :if={@has_next}
          patch={pagination_href(@base_path, @query, @limit, @next_cursor, @extra_params)}
          class="join-item btn btn-sm btn-outline"
        >
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.link>
        <button :if={not @has_next} class="join-item btn btn-sm btn-outline" disabled>
          Next <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp pagination_href(base_path, query, limit, cursor, extra_params) do
    base =
      extra_params
      |> normalize_query_params()
      |> Map.merge(%{"q" => query, "limit" => limit, "cursor" => cursor})

    base_path <> "?" <> URI.encode_query(base)
  end

  defp normalize_query_params(%{} = params) do
    params
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp normalize_query_params(_), do: %{}

  defp pagination_text(count, _limit) when is_integer(count) and count > 0 do
    "Showing #{count} result#{if count != 1, do: "s", else: ""}"
  end

  defp pagination_text(_, _), do: "No results"
end
