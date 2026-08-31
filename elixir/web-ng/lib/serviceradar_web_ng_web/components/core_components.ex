defmodule ServiceRadarWebNGWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: ServiceRadarWebNGWeb.Gettext

  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> then(fn assigns ->
        assigns
        |> assign(:flash_msg, Phoenix.Flash.get(assigns.flash, assigns.kind))
        # Reconnect flashes use phx-connected JS, not the top-layer popover.
        |> assign(:top_layer?, assigns.id not in ["client-error", "server-error"])
      end)

    ~H"""
    <div
      id={@id}
      phx-hook={if @top_layer?, do: "ToastTopLayer"}
      popover={if @top_layer?, do: "manual"}
      data-toast-kind={@kind}
      data-toast-message={@flash_msg}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind})}
      role="alert"
      class="sr-toast"
      {@rest}
    >
      <div
        :if={render_slot(@inner_block) || @flash_msg}
        class={[
          "flex w-80 max-w-[calc(100vw-2rem)] items-start gap-3 rounded-sr-surface border p-3.5 text-sm text-wrap shadow-sr-raised sm:w-96",
          @kind == :info && "border-sky-500/30 bg-sr-raised text-sr-ink",
          @kind == :error && "border-rose-500/35 bg-sr-raised text-sr-ink"
        ]}
      >
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-sky-600 dark:text-sky-300"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-rose-600 dark:text-rose-300"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold text-sr-ink">{@title}</p>
          <p class="text-sr-muted">{render_slot(@inner_block) || @flash_msg}</p>
        </div>
        <button
          type="button"
          class="group shrink-0 cursor-pointer rounded-sr-small p-0.5 text-sr-muted outline-none hover:text-sr-ink focus-visible:ring-2 focus-visible:ring-sr-focus"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5 opacity-60 group-hover:opacity-100" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # Token-based defaults (shared with marketing/control). Callers may override via class=.
    variants = %{
      "primary" =>
        "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-sr-control border border-transparent bg-sr-brand px-3.5 text-sm font-semibold text-sr-on-brand shadow-sr-button outline-none transition-[transform,background-color] duration-200 ease-sr-out hover:bg-sr-brand-strong focus-visible:ring-2 focus-visible:ring-sr-focus active:translate-y-px disabled:pointer-events-none disabled:opacity-50",
      nil =>
        "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-sr-control border border-sr-line bg-sr-subtle px-3.5 text-sm font-semibold text-sr-brand shadow-sr-control outline-none transition-[transform,background-color,border-color] duration-200 ease-sr-out hover:border-sr-line-hover hover:bg-sr-control focus-visible:ring-2 focus-visible:ring-sr-focus active:translate-y-px disabled:pointer-events-none disabled:opacity-50"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        Map.fetch!(variants, assigns[:variant])
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"
  attr :wrapper_class, :any, default: nil, doc: "override the wrapper class for the input"
  attr :label_class, :any, default: nil, doc: "override the label class for the input"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    # Show errors if the field was used OR if the form has errors (e.g., after submission)
    errors =
      if Phoenix.Component.used_input?(field) || field.errors != [], do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={@wrapper_class || "mb-3 grid gap-1.5"}>
      <label class="flex min-h-11 cursor-pointer items-start gap-3 text-sm text-sr-ink">
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
          class={
            @class ||
              "mt-0.5 size-4 shrink-0 rounded border-sr-line-strong text-sr-brand accent-sr-brand focus-visible:ring-2 focus-visible:ring-sr-focus"
          }
          {@rest}
        />
        <span :if={@label} class={@label_class || "pt-0.5 font-medium"}>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={@wrapper_class || "mb-3 grid gap-1.5"}>
      <label class="grid gap-1.5">
        <span :if={@label} class={@label_class || "text-sm font-medium text-sr-ink"}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || sr_field_class(),
            @errors != [] && (@error_class || sr_field_error_class())
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={@wrapper_class || "mb-3 grid gap-1.5"}>
      <label class="grid gap-1.5">
        <span :if={@label} class={@label_class || "text-sm font-medium text-sr-ink"}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || [sr_field_class(), "min-h-24 py-2.5"],
            @errors != [] && (@error_class || sr_field_error_class())
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class={@wrapper_class || "mb-3 grid gap-1.5"}>
      <label class="grid gap-1.5">
        <span :if={@label} class={@label_class || "text-sm font-medium text-sr-ink"}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || sr_field_class(),
            @errors != [] && (@error_class || sr_field_error_class())
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp sr_field_class do
    "w-full min-h-11 rounded-sr-control border border-sr-line bg-sr-control px-3.5 text-sm text-sr-ink shadow-sr-control outline-none transition-[border-color,box-shadow] duration-200 ease-sr-out placeholder:text-sr-muted focus-visible:border-sr-line-hover focus-visible:ring-2 focus-visible:ring-sr-focus disabled:cursor-not-allowed disabled:opacity-60"
  end

  defp sr_field_error_class do
    "border-rose-500/60 focus-visible:ring-rose-500/30"
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-0.5 flex items-center gap-2 text-sm text-rose-600 dark:text-rose-300">
      <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-sr-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a canonical UTC timestamp that the `UserTime` hook can localize in an
  explicitly selected IANA timezone.
  """
  attr :value, :any, required: true
  attr :timezone, :string, default: "Etc/UTC"
  attr :style, :atom, default: :full, values: [:full, :compact, :date, :time, :axis]
  attr :fallback, :string, default: "—"
  attr :id, :string, required: true
  attr :class, :string, default: nil

  def user_time(assigns) do
    case canonical_user_time(assigns.value) do
      {:ok, iso} ->
        assigns =
          assigns
          |> assign(:iso, iso)
          |> assign(:zone, assigns.timezone || "Etc/UTC")

        ~H"""
        <time
          id={@id}
          class={@class}
          datetime={@iso}
          phx-hook="UserTime"
          data-user-time-iso={@iso}
          data-user-time-zone={@zone}
          data-user-time-style={@style}
          data-user-time-fallback={@iso}
          data-user-time-title={"#{@iso} (UTC); display zone #{@zone}"}
          data-user-time-aria-label={"#{@iso} UTC; display zone #{@zone}"}
          title={"#{@iso} (UTC); display zone #{@zone}"}
          aria-label={"#{@iso} UTC; display zone #{@zone}"}
        >{@iso}</time>
        """

      :error ->
        assigns = assign(assigns, :fallback_text, assigns.fallback)

        ~H"""
        <span class={@class}>{@fallback_text}</span>
        """
    end
  end

  defp canonical_user_time(%DateTime{} = value) do
    {:ok, value |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()}
  end

  defp canonical_user_time(%NaiveDateTime{} = value) do
    {:ok, value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()}
  end

  defp canonical_user_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, canonical_iso8601(value, datetime)}
      _error -> :error
    end
  end

  defp canonical_user_time(_value), do: :error

  defp canonical_iso8601(value, _datetime) when is_binary(value) do
    if String.ends_with?(value, "Z"), do: value, else: canonical_iso8601_from_offset(value)
  end

  defp canonical_iso8601_from_offset(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="sr-ui-table-shell">
      <table class={ServiceRadarWebNGWeb.UIComponents.ui_table_class(size: "sm", zebra: true)}>
        <thead>
          <tr>
            <th :for={col <- @col}>{col[:label]}</th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={@row_click && "hover:cursor-pointer"}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-semibold">
              <div class="flex gap-4">
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

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from `assets/vendor/heroicons` and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :title, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} title={@title} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ServiceRadarWebNGWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ServiceRadarWebNGWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
