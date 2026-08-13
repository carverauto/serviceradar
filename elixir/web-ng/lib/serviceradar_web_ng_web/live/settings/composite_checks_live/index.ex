defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Index do
  @moduledoc """
  LiveView for authoring composite service checks.

  A composite check derives one verdict per device from signals other subsystems
  already produce — per-agent reachability and device metadata facts. It never
  probes, so the sweeps that feed it are authored in Networks and shown here as
  read-only context.

  Sited under Networks beside Availability Sources and Visibility Profiles: all
  three scope a device population with SRQL and select agents, and composite
  checks consume exactly what the sweeps configured there produce.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Components

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Rollup
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.FormState
  alias ServiceRadarWebNGWeb.Settings.Shell
  alias ServiceRadarWebNGWeb.SRQL.ScopeBuilder

  require Ash.Query

  @current_path "/settings/networks/composite-checks"
  @view_permission "composite_checks.view"
  @manage_permission "composite_checks.manage"
  @evaluate_permission "composite_checks.evaluate"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @view_permission) do
      {:ok,
       socket
       |> assign(:page_title, "Composite Checks")
       |> assign(:current_path, @current_path)
       |> assign(:can_manage, RBAC.can?(scope, @manage_permission))
       |> assign(:can_evaluate, RBAC.can?(scope, @evaluate_permission))
       |> assign(:editing, nil)
       |> assign(:form, FormState.default_form())
       |> assign(:errors, [])
       |> assign(:save_error, nil)
       |> assign(:builder, ScopeBuilder.default_builder_state())
       |> assign(:builder_in_sync, true)
       |> assign(:scope_count, nil)
       |> assign(:vantage_points, [])
       |> assign(:agents, [])
       |> assign(:checks, list_checks(socket))}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Composite Checks")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Composite Checks")
    |> assign(:editing, nil)
  end

  defp apply_action(socket, :new, _params) do
    if socket.assigns.can_manage do
      socket
      |> assign(:page_title, "New Composite Check")
      |> assign(:editing, :new)
      |> load_form(FormState.default_form())
    else
      forbid(socket)
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    with true <- socket.assigns.can_manage,
         {:ok, check} <- CompositeCheck.get_by_id(id, scope: scope) do
      socket
      |> assign(:page_title, "Edit Composite Check")
      |> assign(:editing, check)
      |> load_form(FormState.form_from_check(check), load_vantage_points(check, scope))
    else
      false ->
        forbid(socket)

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That composite check no longer exists")
        |> push_patch(to: @current_path)
    end
  end

  defp load_form(socket, form, vantage_points \\ []) do
    {builder, in_sync?} = ScopeBuilder.parse_query_to_builder(form["scope_query"])

    socket
    |> assign(:form, form)
    |> assign(:errors, [])
    |> assign(:save_error, nil)
    |> assign(:builder, builder)
    |> assign(:builder_in_sync, in_sync?)
    |> assign(:vantage_points, vantage_points)
    |> assign(:agents, list_agents(socket))
    |> assign(:scope_count, count_scope(socket.assigns.current_scope, form["scope_query"]))
  end

  # Every agent, not just connected ones. A vantage point is durable
  # configuration: an agent that is temporarily down should stay selected, and
  # its input correctly resolves `unknown` until it reports again.
  defp list_agents(socket) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: socket.assigns.current_scope)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read()
    |> case do
      {:ok, agents} -> agents
      {:error, _reason} -> []
    end
  end

  defp load_vantage_points(check, scope) do
    case CompositeCheckInput.list_by_check(check.id, scope: scope) do
      {:ok, inputs} -> FormState.vantage_points_from_inputs(inputs)
      {:error, _reason} -> []
    end
  end

  defp forbid(socket) do
    socket
    |> put_flash(:error, "You do not have permission to manage composite checks")
    |> push_patch(to: @current_path)
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, revalidate(socket, params)}
  end

  def handle_event("add_filter", _params, socket) do
    filters = Map.get(socket.assigns.builder, "filters", []) ++ [blank_filter()]
    {:noreply, sync_from_builder(socket, %{"filters" => filters})}
  end

  def handle_event("remove_filter", %{"index" => index}, socket) do
    index = String.to_integer(index)
    filters = socket.assigns.builder |> Map.get("filters", []) |> List.delete_at(index)

    # Never leave the operator with no way to add the first row back.
    filters = if filters == [], do: [blank_filter()], else: filters

    {:noreply, sync_from_builder(socket, %{"filters" => filters})}
  end

  def handle_event("add_vantage_point", _params, socket) do
    if socket.assigns.can_manage do
      rows = socket.assigns.vantage_points ++ [FormState.blank_vantage_point()]
      {:noreply, assign_vantage_points(socket, rows)}
    else
      {:noreply, forbid(socket)}
    end
  end

  def handle_event("remove_vantage_point", %{"index" => index}, socket) do
    if socket.assigns.can_manage do
      rows = List.delete_at(socket.assigns.vantage_points, String.to_integer(index))
      {:noreply, assign_vantage_points(socket, rows)}
    else
      {:noreply, forbid(socket)}
    end
  end

  def handle_event("save", params, socket) do
    if socket.assigns.can_manage do
      socket = revalidate(socket, params)

      case socket.assigns.errors do
        [] -> persist(socket)
        _errors -> {:noreply, socket}
      end
    else
      {:noreply, forbid(socket)}
    end
  end

  # The raw SRQL field is authoritative. The builder rows live inside the same
  # form, so their params arrive on every change and every submit — deriving the
  # query from them unconditionally would let an empty default filter row wipe
  # whatever the operator typed. Only a change originating from a builder input
  # rewrites the query, which `_target` is what tells us.
  defp revalidate(socket, params) do
    form = FormState.normalize_form(params["form"])

    form =
      if builder_target?(params["_target"]) do
        Map.put(form, "scope_query", query_from_builder(socket, params["builder"]))
      else
        form
      end

    {builder, in_sync?} = ScopeBuilder.parse_query_to_builder(form["scope_query"])

    rows = vantage_points_from_params(socket, params["vantage_points"])

    socket
    |> assign(:form, form)
    |> assign(:vantage_points, rows)
    |> assign(:errors, FormState.validate(form) ++ FormState.validate_vantage_points(rows))
    |> assign(:builder_in_sync, in_sync?)
    |> assign(:scope_count, count_scope(socket.assigns.current_scope, form["scope_query"]))
    |> then(fn socket -> if in_sync?, do: assign(socket, :builder, builder), else: socket end)
  end

  # Indexed params must sort numerically: lexical ordering puts "10" between
  # "1" and "2" and silently reorders the vantage points.
  defp vantage_points_from_params(socket, params) when is_map(params) do
    params
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
    |> Enum.map(fn {_key, value} -> Map.merge(FormState.blank_vantage_point(), value) end)
  rescue
    _ -> socket.assigns.vantage_points
  end

  defp vantage_points_from_params(socket, _params), do: socket.assigns.vantage_points

  defp assign_vantage_points(socket, rows) do
    socket
    |> assign(:vantage_points, rows)
    |> assign(
      :errors,
      FormState.validate(socket.assigns.form) ++ FormState.validate_vantage_points(rows)
    )
  end

  defp builder_target?(["builder" | _rest]), do: true
  defp builder_target?(_target), do: false

  defp query_from_builder(socket, builder_params) when is_map(builder_params) do
    socket.assigns.builder
    |> ScopeBuilder.update_builder(builder_params)
    |> ScopeBuilder.build_query()
  end

  defp query_from_builder(socket, _builder_params), do: socket.assigns.form["scope_query"]

  defp sync_from_builder(socket, builder) do
    query = ScopeBuilder.build_query(builder)
    form = Map.put(socket.assigns.form, "scope_query", query)

    socket
    |> assign(:builder, builder)
    |> assign(:builder_in_sync, true)
    |> assign(:form, form)
    |> assign(:errors, FormState.validate(form))
    |> assign(:scope_count, count_scope(socket.assigns.current_scope, query))
  end

  defp blank_filter, do: %{"field" => "", "op" => "equals", "value" => ""}

  defp persist(socket) do
    scope = socket.assigns.current_scope
    attrs = FormState.to_attrs(socket.assigns.form)

    result =
      case socket.assigns.editing do
        :new ->
          CompositeCheck
          |> Ash.Changeset.for_create(:create, attrs, scope: scope)
          |> Ash.create()

        check ->
          # Renaming is allowed; the slug is writable? false and stays put, so
          # saved SRQL referencing composite.<slug> keeps working.
          check
          |> Ash.Changeset.for_update(:update, attrs, scope: scope)
          |> Ash.update()
      end

    case result do
      {:ok, check} ->
        case sync_vantage_points(check, socket.assigns.vantage_points, scope) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Composite check saved")
             |> push_navigate(to: @current_path)}

          {:error, error} ->
            {:noreply, assign(socket, :save_error, FormState.error_message(error))}
        end

      {:error, error} ->
        {:noreply, assign(socket, :save_error, FormState.error_message(error))}
    end
  end

  # Replace the check's vantage point inputs with the submitted rows.
  #
  # Delete-then-create rather than a diff: the input key is the agent id, so a
  # reassigned row is a different input entirely, and reconciling that by hand
  # would be more code and more ways to leave a stale row behind. Rules
  # reference inputs by key, not by id, so recreating an input with the same key
  # leaves the rule table intact.
  defp sync_vantage_points(check, rows, scope) do
    with {:ok, existing} <- CompositeCheckInput.list_by_check(check.id, scope: scope),
         :ok <- destroy_all(Enum.filter(existing, &(&1.kind == :vantage_point)), scope) do
      rows
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
        CompositeCheckInput
        |> Ash.Changeset.for_create(
          :create,
          FormState.vantage_point_attrs(check.id, row, index),
          scope: scope
        )
        |> Ash.create()
        |> case do
          {:ok, _input} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp destroy_all(inputs, scope) do
    Enum.reduce_while(inputs, :ok, fn input, :ok ->
      case Ash.destroy(input, scope: scope) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # Reads run in mount, which LiveView calls twice — once disconnected for the
  # static render and again on connect. Loading a bounded settings list in both
  # is what the sibling settings views do; the scope count is the expensive part
  # and is deferred to the connected render.
  defp list_checks(socket) do
    scope = socket.assigns.current_scope

    CompositeCheck
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read()
    |> case do
      {:ok, checks} -> decorate(checks, scope, connected?(socket))
      {:error, _reason} -> []
    end
  end

  defp decorate(checks, scope, count_scopes?) do
    rollups = Rollup.for_checks(Enum.map(checks, & &1.id))

    Enum.map(checks, fn check ->
      %{
        check: check,
        rollup: Map.get(rollups, check.id),
        scope_count: count_scopes? && count_scope(scope, check.scope_query)
      }
    end)
  end

  # One SRQL stats query per check. Mirrors the approach in
  # `visibility_profiles_live/index.ex`, which already handles the `in:`-prefixed
  # and bare-filter forms. Returns nil rather than raising: a scope that no
  # longer parses should not take the index down with it.
  defp count_scope(_scope, query) when query in [nil, ""], do: nil

  defp count_scope(scope, query) when is_binary(query) do
    trimmed = String.trim(query)

    full =
      cond do
        trimmed == "" -> ~s|in:devices stats:"count() as total"|
        String.starts_with?(trimmed, "in:") -> ~s|#{trimmed} stats:"count() as total"|
        true -> ~s|in:devices #{trimmed} stats:"count() as total"|
      end

    case srql_module().query(full, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) -> count
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <.check_form
          :if={@editing}
          form={@form}
          errors={@errors}
          mode={if @editing == :new, do: :new, else: :edit}
          scope_count={@scope_count}
          builder={@builder}
          builder_in_sync={@builder_in_sync}
          save_error={@save_error}
          vantage_points={@vantage_points}
          agents={@agents}
        />

        <div :if={is_nil(@editing)} class="space-y-6">
          <header class="flex items-start justify-between gap-4">
            <div>
              <h1 class="text-xl font-semibold text-sr-ink">Composite Checks</h1>
              <p class="mt-1 max-w-2xl text-sm text-sr-ink-muted">
                Prove a device is isolated by combining what several agents can reach with the
                configuration NCO reports. Checks read existing sweep results; they never probe.
              </p>
            </div>
            <.button
              :if={@can_manage}
              variant="primary"
              navigate={~p"/settings/networks/composite-checks/new"}
            >
              New check
            </.button>
          </header>

          <div :if={@checks == []} class="rounded-sr-control border border-sr-border p-8 text-center">
            <.icon name="hero-shield-check" class="mx-auto size-8 text-sr-ink-muted" />
            <p class="mt-3 text-sm font-medium text-sr-ink">No composite checks yet</p>
            <p class="mx-auto mt-1 max-w-md text-sm text-sr-ink-muted">
              A composite check needs at least two vantage points: one agent expected to reach the
              device, and one expected to be blocked. Without a reachable vantage point a
              powered-off device looks exactly like a perfectly isolated one.
            </p>
          </div>

          <.check_list :if={@checks != []} entries={@checks} can_manage={@can_manage} />
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
