defmodule ServiceRadarWebNGWeb.UIComponents do
  @moduledoc """
  App-level UI primitives built on Tailwind + daisyUI.

  Keep these components small and composable so we can swap/adjust styling
  without touching feature templates.
  """

  use Phoenix.Component

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
    assigns =
      assigns
      |> assign(:computed_class, ui_button_class(assigns))
      |> assign(:link?, rest[:href] || rest[:navigate] || rest[:patch])

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
  slot :inner_block, required: true

  def ui_badge(assigns) do
    assigns = assign(assigns, :computed_class, ui_badge_class(assigns))

    ~H"""
    <span class={@computed_class}>{render_slot(@inner_block)}</span>
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
end
