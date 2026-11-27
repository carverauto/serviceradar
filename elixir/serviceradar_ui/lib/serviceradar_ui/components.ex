defmodule ServiceRadarUI.Components do
  @moduledoc """
  Generic function components styled with the `sr-*` tokens.

  Every component is styled by the `sr-ui-*` rules in
  `priv/css/components.css`, takes a `class` attribute that is merged into its
  root element, and passes other HTML and `phx-*` attributes through a `:global`
  `rest` attribute. No component renders a `style` attribute, an inline script
  or an inline event handler.

  Icons use the Heroicons `hero-*` class convention; keep the Heroicons
  Tailwind plugin that Phoenix generates in your application.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  @button_variants ~w(primary ghost soft neutral outline danger warning info success)
  @button_sizes ~w(xs sm md lg)
  @badge_variants ~w(ghost primary info success warning error outline)

  ## Buttons

  @doc """
  Renders a button, or a link styled as one when `href`, `navigate` or `patch`
  is given.

  ## Examples

      <.button>Save</.button>
      <.button variant="ghost" phx-click="cancel">Cancel</.button>
      <.button navigate={~p"/devices"} variant="outline" size="md">Devices</.button>
  """
  attr :variant, :string, default: "primary", values: @button_variants
  attr :size, :string, default: "sm", values: @button_sizes
  attr :square, :boolean, default: false, doc: "equal width and height, for a single icon"
  attr :active, :boolean, default: false, doc: "marks a toggled or selected button"
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(href navigate patch method download replace name value type disabled form target rel)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assigns
      |> assign(:computed_class, button_class(assigns))
      |> assign(:link?, link_target?(rest))

    ~H"""
    <.link :if={@link?} class={@computed_class} {@rest}>{render_slot(@inner_block)}</.link>
    <button :if={not @link?} class={@computed_class} {button_defaults(@rest)}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a square button for a single icon. Give it an `aria-label`.

      <.icon_button aria-label="Refresh" phx-click="refresh">
        <.icon name="hero-arrow-path" />
      </.icon_button>
  """
  attr :variant, :string, default: "ghost", values: @button_variants
  attr :size, :string, default: "sm", values: @button_sizes
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(href navigate patch method download replace name value type disabled form target rel)

  slot :inner_block, required: true

  def icon_button(assigns) do
    ~H"""
    <.button variant={@variant} size={@size} square active={@active} class={@class} {@rest}>
      {render_slot(@inner_block)}
    </.button>
    """
  end

  @doc """
  The class list `button/1` renders, for styling another element as a button.

  Takes `:variant`, `:size`, `:square`, `:active` and `:class`.
  """
  def button_class(opts) when is_list(opts), do: opts |> Map.new() |> button_class()

  def button_class(assigns) when is_map(assigns) do
    variant = Map.get(assigns, :variant) || "primary"
    size = Map.get(assigns, :size) || "sm"

    [
      "sr-ui-btn",
      "sr-ui-btn-#{pick(variant, @button_variants, "primary")}",
      "sr-ui-btn-#{pick(size, @button_sizes, "sm")}",
      Map.get(assigns, :square) && "sr-ui-btn-square",
      Map.get(assigns, :active) && "sr-ui-btn-active",
      Map.get(assigns, :class)
    ]
  end

  defp link_target?(rest), do: Enum.any?([:href, :navigate, :patch], &Map.get(rest, &1))

  defp button_defaults(rest), do: Map.put_new(rest, :type, "button")

  ## Badge

  @doc """
  Renders a small status badge.

      <.badge variant="success">healthy</.badge>
      <.badge variant={badge_variant_for(@device.status)}>{@device.status}</.badge>
  """
  attr :variant, :string, default: "ghost", values: @badge_variants
  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    variant = pick(assigns.variant, @badge_variants, "ghost")
    assigns = assign(assigns, :variant_class, "sr-ui-badge-#{variant}")

    ~H"""
    <span class={["sr-ui-badge", @variant_class, "sr-ui-badge-#{@size}", @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Maps a common status or severity word to a `badge/1` variant.

      iex> ServiceRadarUI.Components.badge_variant_for("Degraded")
      "warning"
      iex> ServiceRadarUI.Components.badge_variant_for(:critical)
      "error"
  """
  def badge_variant_for(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> badge_variant_for()

  def badge_variant_for(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ~w(critical fatal error failed down danger destructive) -> "error"
      v when v in ~w(high warning warn degraded pending at_risk) -> "warning"
      v when v in ~w(success ok up healthy low resolved) -> "success"
      v when v in ~w(info medium running active) -> "info"
      "primary" -> "primary"
      "outline" -> "outline"
      _ -> "ghost"
    end
  end

  def badge_variant_for(_value), do: "ghost"

  ## Panel and surface

  @doc """
  Renders a bordered panel with an optional header and actions.

      <.panel>
        <:header>Devices</:header>
        <:actions><.button size="xs">Add</.button></:actions>
        ...
      </.panel>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :header_class, :any, default: nil
  attr :body_class, :any, default: nil
  attr :flush, :boolean, default: false, doc: "removes the body padding, for tables"
  attr :rest, :global
  slot :header
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["sr-ui-panel", @class]} {@rest}>
      <header :if={@header != [] or @actions != []} class={["sr-ui-panel-header", @header_class]}>
        <div class="sr-ui-panel-title">{render_slot(@header)}</div>
        <div :if={@actions != []} class="sr-ui-panel-actions">{render_slot(@actions)}</div>
      </header>
      <div class={["sr-ui-panel-body", @flush && "sr-ui-panel-body-flush", @body_class]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  Renders a plain token-styled surface.

      <.surface variant="raised" padding="lg">...</.surface>
  """
  attr :variant, :string, default: "surface", values: ~w(surface raised subtle)
  attr :padding, :string, default: "md", values: ~w(none sm md lg)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def surface(assigns) do
    ~H"""
    <div
      class={[
        "sr-ui-surface",
        "sr-ui-surface-#{@variant}",
        "sr-ui-pad-#{@padding}",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  ## Alert and flash

  @doc """
  Renders an inline alert.

      <.alert variant="warning" title="Collector offline">
        No data since 10:42.
      </.alert>
  """
  attr :variant, :string, default: "info", values: ~w(info success warning error ghost)
  attr :title, :string, default: nil
  attr :icon, :string, default: nil, doc: "a hero-* icon; defaults by variant, false hides it"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def alert(assigns) do
    assigns = assign(assigns, :icon_name, alert_icon(assigns.icon, assigns.variant))

    ~H"""
    <div role="alert" class={["sr-ui-alert", "sr-ui-alert-#{@variant}", @class]} {@rest}>
      <.icon :if={@icon_name} name={@icon_name} class="sr-ui-alert-icon" />
      <div class="sr-ui-alert-body">
        <p :if={@title} class="sr-ui-alert-title">{@title}</p>
        <div>{render_slot(@inner_block)}</div>
      </div>
      <div :if={@actions != []} class="sr-ui-alert-actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  defp alert_icon(false, _variant), do: nil
  defp alert_icon(icon, _variant) when is_binary(icon), do: icon
  defp alert_icon(nil, "error"), do: "hero-exclamation-circle"
  defp alert_icon(nil, "warning"), do: "hero-exclamation-triangle"
  defp alert_icon(nil, "success"), do: "hero-check-circle"
  defp alert_icon(nil, _variant), do: "hero-information-circle"

  @doc """
  Renders a flash notice. Clicking it clears the flash.

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} title="Saved with warnings">Two fields were ignored.</.flash>
  """
  attr :id, :string, doc: "the optional id of the flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :close_label, :string, default: "Close"
  attr :class, :any, default: nil
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> assign(:message, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <div
      :if={@message || @inner_block != []}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role="alert"
      class={["sr-ui-flash", "sr-ui-flash-#{@kind}", @class]}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-information-circle"}
        class="sr-ui-flash-icon"
      />
      <div class="sr-ui-flash-body">
        <p :if={@title} class="sr-ui-flash-title">{@title}</p>
        <p class="sr-ui-flash-message">{render_slot(@inner_block) || @message}</p>
      </div>
      <button type="button" class="sr-ui-flash-close" aria-label={@close_label}>
        <.icon name="hero-x-mark" class="sr-ui-icon-md" />
      </button>
    </div>
    """
  end

  ## Modal

  @doc """
  Renders a modal `<dialog>`.

  The `SrDialog` hook from `priv/static/serviceradar_ui.js` opens it with
  `showModal()` so it sits in the browser top layer, traps focus and pushes
  `on_cancel` on Escape or a backdrop click. Render the modal only while it is
  open (`:if`) and close it from the server.

      <.modal :if={@editing} id="edit-device" on_cancel="close_edit">
        <:title>Edit device</:title>
        ...
        <:actions>
          <.button variant="ghost" phx-click="close_edit">Cancel</.button>
          <.button type="submit" form="device-form">Save</.button>
        </:actions>
      </.modal>
  """
  attr :id, :string, required: true
  attr :size, :string, default: "md", values: ~w(sm md lg xl 2xl)

  attr :on_cancel, :any,
    default: nil,
    doc: "event name pushed on Escape, backdrop click and close"

  attr :on_cancel_target, :any, default: nil, doc: "phx-target for `on_cancel`"
  attr :static_backdrop, :boolean, default: false, doc: "ignore backdrop clicks"
  attr :show_close, :boolean, default: true
  attr :close_label, :string, default: "Close"
  attr :hook, :string, default: "SrDialog", doc: "set to nil to render without the dialog hook"
  attr :class, :any, default: nil
  attr :box_class, :any, default: nil
  attr :rest, :global
  slot :title
  slot :actions
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["sr-ui-modal", @hook == nil && "sr-ui-modal-open", @class]}
      phx-hook={@hook}
      open={@hook == nil}
      data-cancel={@on_cancel}
      data-cancel-target={@on_cancel_target}
      data-static-backdrop={@static_backdrop && "true"}
      aria-labelledby={@title != [] && "#{@id}-title"}
      aria-modal="true"
      {@rest}
    >
      <div class={["sr-ui-modal-box", "sr-ui-modal-box-#{@size}", @box_class]}>
        <.icon_button
          :if={@show_close && @on_cancel}
          class="sr-ui-modal-close"
          phx-click={@on_cancel}
          phx-target={@on_cancel_target}
          aria-label={@close_label}
        >
          <.icon name="hero-x-mark" />
        </.icon_button>
        <h2 :if={@title != []} id={"#{@id}-title"} class="sr-ui-modal-title">
          {render_slot(@title)}
        </h2>
        <div class="sr-ui-modal-body">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="sr-ui-modal-action">{render_slot(@actions)}</div>
      </div>
    </dialog>
    """
  end

  ## Tabs and dropdown

  @doc """
  Renders a row of tabs. Each tab is a link (`href`, `navigate`, `patch`) or
  a button that pushes `click` with `phx-value-tab` set to the tab's `value`.

      <.tabs aria-label="Device views">
        <:tab patch={~p"/devices?view=list"} active={@view == "list"}>List</:tab>
        <:tab click="set_view" value="map" active={@view == "map"}>Map</:tab>
      </.tabs>
  """
  attr :variant, :string, default: "boxed", values: ~w(boxed plain)
  attr :class, :any, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :active, :boolean
    attr :href, :string
    attr :navigate, :string
    attr :patch, :string
    attr :click, :any
    attr :target, :any
    attr :value, :any
    attr :disabled, :boolean
  end

  def tabs(assigns) do
    ~H"""
    <nav class={["sr-ui-tabs", @variant == "boxed" && "sr-ui-tabs-boxed", @class]} {@rest}>
      <%= for tab <- @tab do %>
        <.link
          :if={tab[:href] || tab[:navigate] || tab[:patch]}
          href={tab[:href]}
          navigate={tab[:navigate]}
          patch={tab[:patch]}
          class={["sr-ui-tab", tab[:active] && "sr-ui-tab-active"]}
          aria-current={tab[:active] && "page"}
        >
          {render_slot(tab)}
        </.link>
        <button
          :if={!(tab[:href] || tab[:navigate] || tab[:patch])}
          type="button"
          class={["sr-ui-tab", tab[:active] && "sr-ui-tab-active"]}
          phx-click={tab[:click]}
          phx-target={tab[:target]}
          phx-value-tab={tab[:value]}
          disabled={tab[:disabled]}
          aria-pressed={if tab[:active], do: "true", else: "false"}
        >
          {render_slot(tab)}
        </button>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders a menu on a native `<details>` element, so it needs no JavaScript.

      <.dropdown label="Row actions">
        <:trigger><.icon name="hero-ellipsis-vertical" /></:trigger>
        <:item><.link navigate={~p"/devices/\#{@id}"}>Open</.link></:item>
        <:item><button phx-click="delete" phx-value-id={@id}>Delete</button></:item>
      </.dropdown>
  """
  attr :label, :string, default: nil, doc: "accessible label for the trigger"
  attr :align, :string, default: "end", values: ~w(start end)
  attr :placement, :string, default: "bottom", values: ~w(bottom top)
  attr :class, :any, default: nil
  attr :menu_class, :any, default: nil
  attr :rest, :global
  slot :trigger, required: true
  slot :item, required: true

  def dropdown(assigns) do
    ~H"""
    <details class={["sr-ui-dropdown", @class]} {@rest}>
      <summary class="sr-ui-dropdown-trigger" aria-label={@label}>
        <span class="sr-ui-dropdown-trigger-content">{render_slot(@trigger)}</span>
      </summary>
      <ul
        class={[
          "sr-ui-dropdown-menu",
          "sr-ui-dropdown-#{@align}",
          "sr-ui-dropdown-#{@placement}",
          @menu_class
        ]}
        role="menu"
      >
        <li :for={item <- @item} class="sr-ui-dropdown-item" role="none">{render_slot(item)}</li>
      </ul>
    </details>
    """
  end

  ## Table and pagination

  @doc """
  Renders a data table. Accepts a list or a `Phoenix.LiveView.LiveStream`.

      <.table id="devices" rows={@streams.devices} row_click={&JS.navigate(~p"/devices/\#{elem(&1, 1).id}")}>
        <:col :let={{_id, device}} label="Name">{device.name}</:col>
        <:col :let={{_id, device}} label="Status">
          <.badge variant={badge_variant_for(device.status)}>{device.status}</.badge>
        </:col>
        <:action :let={{_id, device}}><.link navigate={~p"/devices/\#{device.id}"}>Open</.link></:action>
        <:empty>No devices yet.</:empty>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :zebra, :boolean, default: false
  attr :fixed, :boolean, default: false
  attr :actions_label, :string, default: "Actions"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
  end

  slot :action, doc: "the slot for showing row actions in the last column"
  slot :empty, doc: "rendered in place of the rows when the list is empty"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class={["sr-ui-table-shell", @class]} {@rest}>
      <table class={table_class(size: @size, zebra: @zebra, fixed: @fixed)}>
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []} class="sr-ui-table-actions">
              <span class="sr-ui-sr-only">{@actions_label}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :if={@empty != [] and empty_rows?(@rows)} id={"#{@id}-empty"}>
            <td class="sr-ui-table-empty" colspan={length(@col) + if(@action != [], do: 1, else: 0)}>
              {render_slot(@empty)}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={@row_click && "sr-ui-table-row-clickable"}
          >
            <td :for={col <- @col} phx-click={@row_click && @row_click.(row)} class={col[:class]}>
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="sr-ui-table-actions">
              <div class="sr-ui-table-actions-inner">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp empty_rows?(rows) when is_list(rows), do: rows == []
  defp empty_rows?(_stream), do: false

  @doc """
  The class list `table/1` puts on its `<table>`, for hand-written tables.

  Options: `:size` (`"xs" | "sm" | "md"`), `:zebra`, `:fixed`, `:class`.

      <table class={table_class(size: "xs", zebra: true)}>
  """
  def table_class(opts \\ []) when is_list(opts) do
    size = opts |> Keyword.get(:size, "sm") |> to_string()

    [
      "sr-ui-table",
      "sr-ui-table-#{pick(size, ~w(xs sm md), "sm")}",
      truthy?(Keyword.get(opts, :zebra)) && "sr-ui-table-zebra",
      truthy?(Keyword.get(opts, :fixed)) && "sr-ui-table-fixed",
      Keyword.get(opts, :class)
    ]
  end

  @doc """
  Renders pagination controls for cursor or page based lists.

  Each control pushes `event` (default `"paginate"`) with `phx-value-page`
  and, when cursors are given, `phx-value-cursor`.

      <.pagination
        current_page={@page}
        total_count={@total}
        page_size={50}
        result_count={length(@rows)}
        next_cursor={@next_cursor}
        prev_cursor={@prev_cursor}
      />
  """
  attr :current_page, :integer, default: 1
  attr :page_size, :integer, default: 20
  attr :result_count, :integer, default: 0
  attr :total_count, :integer, default: nil
  attr :prev_cursor, :string, default: nil
  attr :next_cursor, :string, default: nil

  attr :has_next, :boolean,
    default: nil,
    doc: "overrides the next-page check when not using cursors"

  attr :event, :string, default: "paginate"
  attr :target, :any, default: nil
  attr :prev_label, :string, default: "Prev"
  attr :next_label, :string, default: "Next"
  attr :class, :any, default: nil
  attr :rest, :global

  def pagination(assigns) do
    total_pages = total_pages(assigns.total_count, assigns.page_size)

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:has_prev?, assigns.current_page > 1 or present?(assigns.prev_cursor))
      |> assign(:has_next?, has_next?(assigns, total_pages))
      |> assign(:summary, pagination_summary(assigns.result_count, assigns.total_count))

    ~H"""
    <nav class={["sr-ui-pagination", @class]} aria-label="Pagination" {@rest}>
      <div class="sr-ui-pagination-summary">
        <span>{@summary}</span>
        <span :if={@total_pages && @total_pages > 1} class="sr-ui-pagination-pages">
          Page {@current_page} of {@total_pages}
        </span>
      </div>
      <div class="sr-ui-pagination-controls">
        <.button
          :if={@current_page > 2}
          variant="outline"
          phx-click={@event}
          phx-target={@target}
          phx-value-page="1"
          aria-label="First page"
          title="First page"
        >
          <.icon name="hero-chevron-double-left" />
        </.button>
        <.button
          variant="outline"
          disabled={not @has_prev?}
          phx-click={@has_prev? && @event}
          phx-target={@target}
          phx-value-cursor={@prev_cursor}
          phx-value-page={max(@current_page - 1, 1)}
        >
          <.icon name="hero-chevron-left" /> {@prev_label}
        </.button>
        <.button
          variant="outline"
          disabled={not @has_next?}
          phx-click={@has_next? && @event}
          phx-target={@target}
          phx-value-cursor={@next_cursor}
          phx-value-page={@current_page + 1}
        >
          {@next_label} <.icon name="hero-chevron-right" />
        </.button>
      </div>
    </nav>
    """
  end

  defp has_next?(%{has_next: value}, _total_pages) when is_boolean(value), do: value

  defp has_next?(%{next_cursor: cursor}, _total_pages) when is_binary(cursor) and cursor != "",
    do: true

  defp has_next?(%{current_page: page}, total_pages) when is_integer(total_pages),
    do: page < total_pages

  defp has_next?(_assigns, _total_pages), do: false

  defp total_pages(total, size)
       when is_integer(total) and total > 0 and is_integer(size) and size > 0,
       do: div(total + size - 1, size)

  defp total_pages(_total, _size), do: nil

  defp pagination_summary(count, total)
       when is_integer(count) and count > 0 and is_integer(total) and total > 0,
       do: "Showing #{count} of #{format_count(total)} #{plural(total, "result", "results")}"

  defp pagination_summary(count, _total) when is_integer(count) and count > 0,
    do: "Showing #{count} #{plural(count, "result", "results")}"

  defp pagination_summary(_count, _total), do: "No results"

  @doc false
  def format_count(n) when is_integer(n) and n < 0, do: "-" <> format_count(-n)

  def format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_n, _singular, plural), do: plural

  ## Spinner

  @doc """
  Renders a loading spinner. Give the surrounding region `aria-busy` or a
  visible label; the spinner itself is hidden from assistive technology.
  """
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :class, :any, default: nil
  attr :rest, :global

  def spinner(assigns) do
    ~H"""
    <span class={["sr-ui-spinner", "sr-ui-spinner-#{@size}", @class]} aria-hidden="true" {@rest}></span>
    """
  end

  ## Forms

  @doc """
  Renders a label, hint and error messages around any control.

  Use it for controls `input/1` does not cover:

      <.field label="Schedule" for="schedule" errors={@errors}>
        <my-cron-editor id="schedule"></my-cron-editor>
      </.field>
  """
  attr :label, :string, default: nil
  attr :for, :string, default: nil
  attr :hint, :string, default: nil
  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class={["sr-ui-field", @class]} {@rest}>
      <label :if={@label} for={@for} class="sr-ui-label">{@label}</label>
      {render_slot(@inner_block)}
      <p :if={@hint} class="sr-ui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages, following the Phoenix
  generator's `input/1` contract.

  A `Phoenix.HTML.FormField` may be passed as `field`, which supplies the
  name, id, value and errors. Errors go through `ServiceRadarUI.translate_error/1`
  (configure your own translator there; no Gettext dependency).

  `type="select"` renders a `<select>` from `options`, `type="textarea"` a
  `<textarea>`, `type="checkbox"` a boolean checkbox and `type="toggle"` the
  same checkbox styled as a switch.

      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:role]} type="select" options={["Admin": "admin", "User": "user"]} />
      <.input name="q" value={@q} placeholder="Search" size="xs" />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox toggle color date datetime-local email file month number password
               range search select tel text textarea time url week hidden)

  attr :field, FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :variant, :string, default: "bordered", values: ~w(bordered ghost)
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil, doc: "extra classes for the control"
  attr :wrapper_class, :any, default: nil, doc: "extra classes for the wrapper"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows step inputmode)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &ServiceRadarUI.translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: type} = assigns) when type in ["checkbox", "toggle"] do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["sr-ui-field", @wrapper_class]}>
      <label class="sr-ui-check-label">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          role={@type == "toggle" && "switch"}
          class={[if(@type == "toggle", do: "sr-ui-toggle", else: "sr-ui-checkbox"), @class]}
          {@rest}
        />
        <span :if={@label}>{@label}</span>
      </label>
      <p :if={@hint} class="sr-ui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["sr-ui-field", @wrapper_class]}>
      <label :if={@label} for={@id} class="sr-ui-label">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[input_control_class(assigns), "sr-ui-select"]}
        multiple={@multiple}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="sr-ui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["sr-ui-field", @wrapper_class]}>
      <label :if={@label} for={@id} class="sr-ui-label">{@label}</label>
      <textarea
        id={@id}
        name={@name}
        class={[input_control_class(assigns), "sr-ui-textarea"]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Form.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="sr-ui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={["sr-ui-field", @wrapper_class]}>
      <label :if={@label} for={@id} class="sr-ui-label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={input_control_class(assigns)}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <p :if={@hint} class="sr-ui-hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  The class list for a text-like control, for raw `<input>`, `<select>` and
  `<textarea>` elements outside `input/1`.

  Options: `:size` (`"xs" | "sm" | "md" | "lg"`, default `"md"`), `:variant`
  (`"bordered" | "ghost"`), `:mono`, `:invalid`, `:class`.
  """
  def control_class(opts) when is_list(opts) do
    size = opts |> Keyword.get(:size, "md") |> to_string()

    [
      "sr-ui-control",
      "sr-ui-control-#{pick(size, ~w(xs sm md lg), "md")}",
      Keyword.get(opts, :variant) in ["ghost", :ghost] && "sr-ui-control-ghost",
      truthy?(Keyword.get(opts, :mono)) && "sr-ui-control-mono",
      truthy?(Keyword.get(opts, :invalid)) && "sr-ui-control-invalid",
      Keyword.get(opts, :class)
    ]
  end

  defp input_control_class(assigns) do
    control_class(
      size: assigns.size,
      variant: assigns.variant,
      mono: assigns.mono,
      invalid: assigns.errors != [],
      class: assigns.class
    )
  end

  @doc false
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="sr-ui-error">
      <.icon name="hero-exclamation-circle" class="sr-ui-icon-sm" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  ## Icon

  @doc """
  Renders a [Heroicon](https://heroicons.com) through the `hero-*` class
  convention. Outline is the default style; append `-solid`, `-mini` or
  `-micro` for the others.

  The application's Tailwind build must include the Heroicons plugin that
  Phoenix generates (`assets/vendor/heroicons.js`).

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="sr-ui-icon-sm sr-ui-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :label, :string, default: nil, doc: "accessible label; the icon is decorative without one"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span
      class={["sr-ui-icon", @name, @class]}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
      {@rest}
    ></span>
    """
  end

  ## Helpers

  defp pick(value, allowed, default) do
    value = to_string(value)
    if value in allowed, do: value, else: default
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp truthy?(value), do: value in [true, "true"]
end
