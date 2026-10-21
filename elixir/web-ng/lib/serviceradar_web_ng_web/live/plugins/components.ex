defmodule ServiceRadarWebNGWeb.Plugins.Components do
  @moduledoc """
  Function components and view helpers shared by the Wasm plugin LiveViews:
  `Plugins.InstalledLive`, `Plugins.UpdatesLive`, `Plugins.CatalogLive` and
  `Plugins.ShowLive`.

  The plugin pages are served under `/settings/agents/plugins` and, for older
  links, `/admin/plugins`. Each page keeps the prefix it was opened under, so
  every link here takes the base path explicitly.
  """

  use ServiceRadarWebNGWeb, :html

  alias Ash.Error.Invalid

  @settings_base_path "/settings/agents/plugins"
  @admin_base_path "/admin/plugins"

  @tabs [
    {:installed, "Installed", nil},
    {:updates, "Updates", "updates"},
    {:catalog, "Catalog", "catalog"}
  ]

  attr :active, :atom, required: true, doc: "one of :installed, :updates, :catalog or :detail"
  attr :base_path, :string, required: true
  attr :can_stage_plugins, :boolean, default: false
  slot :actions

  @doc "Page title, the Installed / Updates / Catalog tabs, and page actions."
  def plugins_nav(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold text-sr-ink">Plugins</h1>
          <p class="text-sm text-sr-muted">
            Review and publish Wasm plugin packages before they are distributed to agents.
          </p>
        </div>
        <div class="flex gap-2">
          {render_slot(@actions)}
          <.ui_button
            :if={@can_stage_plugins}
            id="plugins-new-package"
            variant="primary"
            size="sm"
            navigate={@base_path <> "/new"}
          >
            <.icon name="hero-plus" class="size-4" /> New Plugin
          </.ui_button>
        </div>
      </div>
      <nav id="plugins-tabs" class="flex gap-1 border-b border-sr-line" aria-label="Plugin views">
        <.link
          :for={{id, label, segment} <- @tabs}
          id={"plugins-tab-#{id}"}
          navigate={plugins_tab_path(@base_path, segment)}
          aria-current={if @active == id, do: "page"}
          class={[
            "-mb-px border-b-2 px-3 py-2 text-sm font-medium transition-colors",
            if(@active == id,
              do: "border-sr-brand text-sr-ink",
              else: "border-transparent text-sr-muted hover:text-sr-ink"
            )
          ]}
        >
          {label}
        </.link>
      </nav>
    </div>
    """
  end

  attr :status, :any, required: true

  @doc "Badge for a package status (`staged`, `approved`, `denied`, `revoked`)."
  def status_badge(assigns) do
    status = if is_atom(assigns.status), do: Atom.to_string(assigns.status), else: assigns.status

    variant =
      case status do
        "staged" -> "warning"
        "approved" -> "success"
        "denied" -> "error"
        "revoked" -> "ghost"
        _ -> "ghost"
      end

    assigns = assigns |> assign(:variant, variant) |> assign(:status_str, status)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@status_str}</.ui_badge>
    """
  end

  def package_status_badge_variant(:approved), do: "success"
  def package_status_badge_variant("approved"), do: "success"
  def package_status_badge_variant(:staged), do: "warning"
  def package_status_badge_variant("staged"), do: "warning"

  def package_status_badge_variant(status) when status in [:denied, :revoked, "denied", "revoked"], do: "error"

  def package_status_badge_variant(_status), do: "ghost"

  attr(:id_prefix, :string, required: true)
  attr(:event, :string, required: true)
  attr(:page, :integer, required: true)
  attr(:total_items, :integer, required: true)
  attr(:page_size, :integer, required: true)

  @doc "Previous / next controls that send `event` with the target page."
  def pagination_controls(assigns) do
    page_count = page_count(assigns.total_items, assigns.page_size)
    {first_item, last_item} = page_range(assigns.total_items, assigns.page, assigns.page_size)

    assigns =
      assign(assigns,
        page_count: page_count,
        first_item: first_item,
        last_item: last_item
      )

    ~H"""
    <div
      :if={@total_items > 0}
      class="flex flex-wrap items-center justify-between gap-3 border-t border-sr-line px-4 py-3 text-xs text-sr-muted"
    >
      <span>
        Showing {@first_item}-{@last_item} of {@total_items}
      </span>
      <div class={ui_join_class()}>
        <.ui_button
          id={"#{@id_prefix}-prev-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          size="xs"
          variant="neutral"
        >
          Previous
        </.ui_button>
        <.ui_button type="button" disabled size="xs" variant="ghost">
          Page {@page} of {@page_count}
        </.ui_button>
        <.ui_button
          id={"#{@id_prefix}-next-page"}
          type="button"
          phx-click={@event}
          phx-value-page={@page + 1}
          disabled={@page >= @page_count}
          size="xs"
          variant="neutral"
        >
          Next
        </.ui_button>
      </div>
    </div>
    """
  end

  @doc "The items of a client-side page of `items`."
  def paginated_items(items, page, page_size) when is_list(items) do
    page = clamp_page(page, length(items), page_size)

    items
    |> Enum.drop((page - 1) * page_size)
    |> Enum.take(page_size)
  end

  @doc "Parses `page` and clamps it to the pages `total_items` fills."
  def clamp_page(page, total_items, page_size) do
    page =
      case page do
        page when is_integer(page) -> page
        page when is_binary(page) -> page |> Integer.parse() |> parsed_page()
        _ -> 1
      end

    page
    |> max(1)
    |> min(page_count(total_items, page_size))
  end

  defp parsed_page({page, _rest}), do: page
  defp parsed_page(:error), do: 1

  defp page_count(total_items, page_size) when is_integer(total_items) and total_items > 0,
    do: max(1, ceil(total_items / page_size))

  defp page_count(_total_items, _page_size), do: 1

  defp page_range(total_items, page, page_size) when total_items > 0 do
    page = clamp_page(page, total_items, page_size)
    first_item = (page - 1) * page_size + 1
    last_item = min(page * page_size, total_items)

    {first_item, last_item}
  end

  defp page_range(_total_items, _page, _page_size), do: {0, 0}

  @doc "The path of a request URL, or `nil`."
  def current_path_from_url(nil), do: nil

  def current_path_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> path
      _ -> nil
    end
  end

  @doc "The plugin pages' base path for the prefix the request URL used."
  def plugins_base_path_from_url(url) do
    path = current_path_from_url(url) || ""

    if String.starts_with?(path, @settings_base_path), do: @settings_base_path, else: @admin_base_path
  end

  @doc "The path of a tab (`nil` for Installed) under `base_path`."
  def plugins_tab_path(base_path, nil), do: base_path
  def plugins_tab_path(base_path, segment), do: base_path <> "/" <> segment

  @doc "The package detail path."
  def plugins_show_path(base_path, id) when is_binary(base_path), do: base_path <> "/#{id}"

  @doc "Package verification settings, from the deployment configuration."
  def plugin_verification_policy do
    config = Application.get_env(:serviceradar_web_ng, :plugin_verification, [])

    %{
      require_gpg_for_github: Keyword.get(config, :require_gpg_for_github, false),
      allow_unsigned_uploads: Keyword.get(config, :allow_unsigned_uploads, true)
    }
  end

  @doc "A value made safe for use inside a DOM id."
  def dom_id_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "-")
  end

  @doc "Parses an optional JSON object from a form field."
  def parse_optional_json_map(nil, _label), do: {:ok, %{}}
  def parse_optional_json_map("", _label), do: {:ok, %{}}

  def parse_optional_json_map(%{} = value, _label), do: {:ok, value}

  def parse_optional_json_map(json, label) when is_binary(json) do
    trimmed = String.trim(json)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, value} when is_map(value) -> {:ok, value}
        {:ok, _} -> {:error, {:invalid_json, "#{label} must be a JSON object"}}
        {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
      end
    end
  end

  def parse_optional_json_map(_value, label), do: {:error, {:invalid_json, "#{label} must be JSON"}}

  @doc "Operator-facing text for a plugin action error."
  def format_error(error) when is_binary(error), do: error
  def format_error(:policy_owned_assignment), do: "assignment is managed by policy"
  def format_error(:target_package_not_approved), do: "target plugin version is not approved"
  def format_error(:plugin_id_mismatch), do: "target package is for a different plugin"
  def format_error(:already_on_target_version), do: "assignment is already on that version"
  def format_error(error) when is_atom(error), do: Atom.to_string(error)
  def format_error(%Invalid{} = error), do: Exception.message(error)
  def format_error(error), do: inspect(error)
end
