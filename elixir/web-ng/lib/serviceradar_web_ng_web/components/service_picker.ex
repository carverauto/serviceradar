defmodule ServiceRadarWebNGWeb.Components.ServicePicker do
  @moduledoc """
  Searchable OTel service picker for the logs, traces and metrics panes.

  A function component (`service_picker/1`, on the shared `ui_modal`) plus the
  event helpers a LiveView delegates to. It does not know about any one pane:
  the host passes the pane's signal tab, its current SRQL query and the path
  params to patch, and routes `service_picker_*` events and the
  `:service_picker` async result here.

  ## Server-side search

  Nothing is queried until the modal is opened (so never on a disconnected
  mount). Opening, and every debounced keystroke after it, runs two catalog
  queries in one `start_async`:

      in:otel_services signal:<tab> [service_name:"%q%"] sort:last_seen:desc limit:50
      in:otel_services signal:<tab> [service_name:"%q%"] stats:"count() as total"

  Each run carries a request token; a result whose token is not the latest is
  dropped, so a slow earlier search can never overwrite a newer one.

  ## Authorization

  Every event re-checks that the scope may view the pane's signal before it
  touches the catalog. SRQL gates `in:otel_services` again on its own.
  """

  use ServiceRadarWebNGWeb, :html

  alias Phoenix.LiveView
  alias ServiceRadarWebNGWeb.Observability.ServiceFilter
  alias ServiceRadarWebNGWeb.ObservabilityPaths
  alias ServiceRadarWebNGWeb.Stats.Extract

  require LiveView

  @result_limit 50
  @async_name :service_picker

  @tab_permissions %{
    "logs" => "observability.logs.view",
    "traces" => "observability.traces.view",
    "metrics" => "observability.metrics.view"
  }

  @typedoc "Picker state, kept under the `:service_picker` assign."
  @type state :: %{
          open?: boolean(),
          tab: String.t() | nil,
          search: String.t(),
          results: [String.t()],
          total: non_neg_integer() | nil,
          loading?: boolean(),
          error: String.t() | nil,
          selected: [String.t()],
          token: non_neg_integer(),
          notice: String.t() | nil
        }

  @doc "Maximum rows one search returns."
  @spec result_limit() :: pos_integer()
  def result_limit, do: @result_limit

  @doc "The async name the host routes to `handle_async/2`."
  @spec async_name() :: atom()
  def async_name, do: @async_name

  @doc "Closed picker state. Runs no query."
  @spec initial_state() :: state()
  def initial_state do
    %{
      open?: false,
      tab: nil,
      search: "",
      results: [],
      total: nil,
      loading?: false,
      error: nil,
      selected: [],
      token: 0,
      notice: nil
    }
  end

  @doc "Assign the closed picker. Safe in a disconnected mount: no query runs."
  @spec init(LiveView.Socket.t()) :: LiveView.Socket.t()
  def init(socket), do: Phoenix.Component.assign(socket, :service_picker, initial_state())

  @doc "True when `scope` may view the signal of `tab`."
  @spec authorized?(term(), String.t() | nil) :: boolean()
  def authorized?(scope, tab) do
    case Map.fetch(@tab_permissions, tab) do
      {:ok, permission} -> ServiceRadarWebNG.RBAC.can?(scope, permission)
      :error -> false
    end
  end

  # -- queries ------------------------------------------------------------------

  @doc "The list query for one search."
  @spec list_query(String.t(), String.t()) :: String.t()
  def list_query(signal, search) do
    "#{base_query(signal, search)} sort:last_seen:desc limit:#{@result_limit}"
  end

  @doc "The match-count query for one search."
  @spec count_query(String.t(), String.t()) :: String.t()
  def count_query(signal, search) do
    ~s|#{base_query(signal, search)} stats:"count() as total"|
  end

  defp base_query(signal, search) do
    case String.trim(search) do
      "" -> "in:otel_services signal:#{signal}"
      term -> ~s|in:otel_services signal:#{signal} service_name:"%#{escape_search(term)}%"|
    end
  end

  defp escape_search(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # -- events -------------------------------------------------------------------

  @doc """
  Handle a `service_picker_*` event.

  `context` is `%{tab: pane_tab, query: pane_query, params: path_params}`.
  Rejects every event (and runs no query) unless the scope may view `tab`.
  """
  @spec handle_event(String.t(), map(), LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def handle_event(event, params, socket, %{tab: tab} = context) do
    cond do
      not authorized?(socket.assigns[:current_scope], tab) ->
        socket
        |> close()
        |> LiveView.put_flash(:error, "You do not have permission to filter this pane by service.")

      # Only opening is valid while closed; anything else is a stale or forged event.
      event != "service_picker_open" and not current(socket).open? ->
        socket

      true ->
        do_handle_event(event, params, socket, context)
    end
  end

  defp do_handle_event("service_picker_open", _params, socket, %{tab: tab, query: query}) do
    state = %{current(socket) | open?: true, tab: tab, selected: ServiceFilter.selected_names(query)}

    socket
    |> put_state(%{state | search: "", results: [], total: nil, error: nil, notice: nil})
    |> run_search()
  end

  defp do_handle_event("service_picker_search", params, socket, _context) do
    search = params |> Map.get("search", "") |> to_string() |> String.slice(0, 255)

    socket
    |> update_state(&%{&1 | search: search, notice: nil})
    |> run_search()
  end

  defp do_handle_event("service_picker_toggle", %{"name" => name}, socket, _context) when is_binary(name) do
    update_state(socket, &toggle(&1, name))
  end

  defp do_handle_event("service_picker_use_typed", _params, socket, _context) do
    update_state(socket, fn state -> select(state, String.trim(state.search)) end)
  end

  defp do_handle_event("service_picker_apply", _params, socket, context) do
    patch_to(socket, context, current(socket).selected)
  end

  defp do_handle_event("service_picker_clear", _params, socket, context) do
    patch_to(socket, context, [])
  end

  defp do_handle_event("service_picker_cancel", _params, socket, _context), do: close(socket)

  defp do_handle_event(_event, _params, socket, _context), do: socket

  defp toggle(state, name) do
    if name in state.selected do
      %{state | selected: List.delete(state.selected, name), notice: nil}
    else
      select(state, name)
    end
  end

  defp select(state, name) do
    cond do
      name == "" or name in state.selected ->
        state

      length(state.selected) >= ServiceFilter.max_selection() ->
        %{state | notice: "A filter can select at most #{ServiceFilter.max_selection()} services."}

      true ->
        %{state | selected: state.selected ++ [name], notice: nil}
    end
  end

  # Replace only the service token, keep every other token, and drop position
  # (cursor/page) so the list reloads from its first page.
  defp patch_to(socket, %{tab: tab, query: query} = context, names) do
    params =
      context
      |> Map.get(:params, %{})
      |> Map.drop(["q", "cursor", "page", "limit", "tab", "service_filter"])
      |> Map.put("q", ServiceFilter.put(query, names))

    socket
    |> close()
    |> LiveView.push_patch(to: ObservabilityPaths.path(tab, params))
  end

  # Closed state that keeps the request token climbing, so a search still in
  # flight from this session can never match a token issued after a reopen.
  defp close(socket), do: put_state(socket, %{initial_state() | token: current(socket).token})

  # -- async ------------------------------------------------------------------

  defp run_search(socket) do
    state = current(socket)
    token = state.token + 1
    signal = state.tab
    search = state.search
    scope = socket.assigns[:current_scope]
    srql = srql_module()

    socket
    |> put_state(%{state | token: token, loading?: true, error: nil})
    |> LiveView.start_async(@async_name, fn ->
      {token, fetch(srql, scope, signal, search)}
    end)
  end

  defp fetch(srql, scope, signal, search) do
    with {:ok, rows} <- list_rows(srql.query(list_query(signal, search), %{scope: scope})),
         {:ok, total} <- Extract.count_total(srql.query(count_query(signal, search), %{scope: scope})) do
      {:ok, rows, total}
    end
  end

  defp list_rows({:ok, %{"results" => results}}) when is_list(results) do
    names =
      results
      |> Enum.flat_map(fn
        %{"service_name" => name} when is_binary(name) and name != "" -> [name]
        _ -> []
      end)
      |> Enum.take(@result_limit)

    {:ok, names}
  end

  defp list_rows({:error, reason}), do: {:error, reason}
  defp list_rows(_other), do: {:error, :invalid_response}

  @doc """
  Apply a `:service_picker` async result. A result from any request but the
  latest, or one that lands after the picker closed, is dropped.
  """
  @spec handle_async({:ok, term()} | {:exit, term()}, LiveView.Socket.t()) :: LiveView.Socket.t()
  def handle_async({:ok, {token, outcome}}, socket) do
    state = current(socket)

    if state.open? and token == state.token do
      put_state(socket, apply_outcome(state, outcome))
    else
      socket
    end
  end

  def handle_async({:exit, _reason}, socket) do
    state = current(socket)

    if state.open? do
      put_state(socket, %{state | loading?: false, error: "Service search failed."})
    else
      socket
    end
  end

  defp apply_outcome(state, {:ok, names, total}) do
    %{state | results: names, total: total, loading?: false, error: nil}
  end

  defp apply_outcome(state, {:error, :forbidden}) do
    %{state | results: [], total: nil, loading?: false, error: "You do not have permission to list these services."}
  end

  defp apply_outcome(state, {:error, _reason}) do
    %{state | results: [], total: nil, loading?: false, error: "Service search failed."}
  end

  defp current(socket), do: Map.get(socket.assigns, :service_picker) || initial_state()
  defp put_state(socket, state), do: Phoenix.Component.assign(socket, :service_picker, state)
  defp update_state(socket, fun), do: put_state(socket, fun.(current(socket)))

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  # -- view helpers -----------------------------------------------------------

  @doc """
  Rows to render: the selection first (pinned, even when the search no
  longer matches it), then the search results not already selected.
  """
  @spec options(state()) :: [%{name: String.t(), selected?: boolean()}]
  def options(state) do
    pinned = Enum.map(state.selected, &%{name: &1, selected?: true})

    rest =
      state.results
      |> Enum.reject(&(&1 in state.selected))
      |> Enum.map(&%{name: &1, selected?: false})

    pinned ++ rest
  end

  @doc "The `N of M` line under the search field."
  @spec count_text(state()) :: String.t()
  def count_text(%{loading?: true}), do: "Searching..."
  def count_text(%{total: total, results: results}) when is_integer(total), do: "Showing #{length(results)} of #{total}"
  def count_text(_state), do: ""

  @doc "True when the free-text fallback should be offered."
  @spec offer_typed?(state()) :: boolean()
  def offer_typed?(state) do
    typed = String.trim(state.search)
    typed != "" and not state.loading? and is_nil(state.error) and state.results == [] and typed not in state.selected
  end

  # -- components -------------------------------------------------------------

  attr :id, :string, required: true
  attr :query, :string, default: ""
  attr :class, :any, default: nil

  @doc "The pane's Service button: `All services`, the one name, or `N services`."
  def service_picker_trigger(assigns) do
    assigns = assign(assigns, :label, trigger_label(ServiceFilter.parse(assigns.query)))

    ~H"""
    <.ui_button
      id={@id}
      type="button"
      phx-click="service_picker_open"
      variant="ghost"
      size="xs"
      class={["rounded-full max-w-[14rem]", @class]}
      title="Filter by OTel service"
    >
      <.icon name="hero-cube-transparent" class="size-4 shrink-0" />
      <span class="truncate text-xs">{@label}</span>
    </.ui_button>
    """
  end

  defp trigger_label(:none), do: "All services"
  defp trigger_label({:exact, names}), do: ServiceFilter.label(names)
  defp trigger_label({:wildcard, pattern}), do: pattern
  defp trigger_label(:unsupported), do: "Custom service filter"

  attr :picker, :map, required: true

  @doc "The picker modal. Renders nothing while closed."
  def service_picker(assigns) do
    picker = assigns.picker

    assigns =
      assigns
      |> assign(:options, options(picker))
      |> assign(:offer_typed?, offer_typed?(picker))
      |> assign(:max_selection, ServiceFilter.max_selection())

    ~H"""
    <.ui_modal
      :if={@picker.open?}
      id="service-picker"
      size="md"
      on_cancel="service_picker_cancel"
    >
      <:title>Filter by service</:title>
      <div id="service-picker-body" phx-hook="ServicePickerKeys" class="space-y-3">
        <form
          id="service-picker-search-form"
          phx-change="service_picker_search"
          phx-submit="service_picker_apply"
        >
          <label for="service-picker-search" class="sr-only">Search services</label>
          <input
            id="service-picker-search"
            type="search"
            name="search"
            value={@picker.search}
            placeholder="Search services"
            autocomplete="off"
            maxlength="255"
            phx-debounce="150"
            data-picker-search
            data-dialog-autofocus
            class="w-full rounded-sr-control border border-sr-line bg-sr-surface px-3 py-2 text-sm text-sr-ink outline-none focus:border-sr-brand"
          />
        </form>

        <div class="flex items-center justify-between text-xs text-sr-muted">
          <span id="service-picker-count">
            {count_text(@picker)}
          </span>
          <span id="service-picker-selected-count">
            {length(@picker.selected)} / {@max_selection} selected
          </span>
        </div>

        <div :if={@picker.error} id="service-picker-error" role="alert" class="text-xs text-rose-400">
          {@picker.error}
        </div>
        <div
          :if={@picker.notice}
          id="service-picker-notice"
          role="status"
          class="text-xs text-amber-400"
        >
          {@picker.notice}
        </div>

        <ul
          id="service-picker-options"
          role="listbox"
          aria-multiselectable="true"
          aria-label="Services"
          class="max-h-80 space-y-0.5 overflow-y-auto"
        >
          <li :for={{option, idx} <- Enum.with_index(@options)} id={"service-picker-option-#{idx}"}>
            <label class="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1 text-sm hover:bg-sr-subtle">
              <input
                type="checkbox"
                checked={option.selected?}
                phx-click="service_picker_toggle"
                phx-value-name={option.name}
                data-picker-option
                data-service-name={option.name}
                class="size-4"
              />
              <span class="truncate font-mono text-xs">{option.name}</span>
            </label>
          </li>
        </ul>

        <div
          :if={
            @options == [] and not @picker.loading? and is_nil(@picker.error) and not @offer_typed?
          }
          id="service-picker-empty"
          class="py-4 text-center text-xs text-sr-muted"
        >
          No services have reported this signal yet.
        </div>

        <.ui_button
          :if={@offer_typed?}
          id="service-picker-use-typed"
          type="button"
          phx-click="service_picker_use_typed"
          variant="outline"
          size="xs"
          class="w-full justify-start"
        >
          Filter by "{String.trim(@picker.search)}" anyway
        </.ui_button>
      </div>

      <:actions>
        <.ui_button
          id="service-picker-clear"
          type="button"
          phx-click="service_picker_clear"
          variant="ghost"
          size="sm"
        >
          Clear
        </.ui_button>
        <.ui_button
          id="service-picker-cancel"
          type="button"
          phx-click="service_picker_cancel"
          variant="ghost"
          size="sm"
        >
          Cancel
        </.ui_button>
        <.ui_button
          id="service-picker-apply"
          type="button"
          phx-click="service_picker_apply"
          variant="primary"
          size="sm"
        >
          Apply
        </.ui_button>
      </:actions>
    </.ui_modal>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, default: nil
  attr :tab, :string, required: true
  attr :query, :string, default: ""
  attr :fallback, :string, default: "—"

  @doc """
  A row's service name as a patch link that applies a single-service filter to
  the pane, keeping its other tokens. A button with `JS.patch` rather than an
  anchor, because the enclosing row has its own `phx-click` and LiveView only
  dispatches the innermost binding.
  """
  def service_row_link(assigns) do
    ~H"""
    <button
      :if={is_binary(@name) and @name != ""}
      id={@id}
      type="button"
      phx-click={JS.patch(row_filter_path(@tab, @query, @name))}
      class="max-w-full truncate text-left hover:text-sr-brand hover:underline"
      title={"Filter by service #{@name}"}
    >
      {@name}
    </button>
    <span :if={not (is_binary(@name) and @name != "")}>{@fallback}</span>
    """
  end

  @doc "Path applying a single-service filter to `query` on `tab`."
  @spec row_filter_path(String.t(), String.t() | nil, String.t()) :: String.t()
  def row_filter_path(tab, query, name) do
    base =
      case String.trim(to_string(query)) do
        "" -> ServiceFilter.default_query(tab) || ""
        current -> current
      end

    ObservabilityPaths.path(tab, %{q: ServiceFilter.put(base, [name])})
  end

  attr :id, :string, required: true
  attr :scope, :any, default: nil

  @doc """
  States what the stat cards cover under a service filter. `scope` is
  `ServiceFilter.stats_scope/1`: nil renders nothing; `:all_services` says the
  cards are NOT narrowed; a list or pattern names what they are narrowed to.
  """
  def stat_scope_badge(assigns) do
    ~H"""
    <div :if={not is_nil(@scope)} id={@id} class="flex items-center gap-2 text-xs text-sr-muted">
      <%= case @scope do %>
        <% :all_services -> %>
          <.ui_badge
            variant="warning"
            size="xs"
            title="These cards cannot be narrowed by the current service filter."
          >
            All services
          </.ui_badge>
          <span>Cards are not scoped by the service filter.</span>
        <% names when is_list(names) -> %>
          <.ui_badge variant="info" size="xs">{ServiceFilter.label(names)}</.ui_badge>
          <span>Cards scoped to {Enum.join(names, ", ")}</span>
        <% pattern -> %>
          <.ui_badge variant="info" size="xs">{pattern}</.ui_badge>
          <span>Cards scoped to services matching {pattern}</span>
      <% end %>
    </div>
    """
  end
end
