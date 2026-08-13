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
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.Rollup
  alias ServiceRadar.CompositeChecks.RuleGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.FormState
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.RuleTable
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
       |> assign(:rules, [])
       |> assign(:rule_columns, [])
       |> assign(:rule_error, nil)
       |> assign(:confirm_regenerate, false)
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
      |> assign(:rules, [])
      |> assign(:rule_columns, [])
    else
      forbid(socket)
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    with true <- socket.assigns.can_manage,
         {:ok, check} <- CompositeCheck.get_by_id(id, scope: scope) do
      inputs = load_inputs(check, scope)

      socket
      |> assign(:page_title, "Edit Composite Check")
      |> assign(:editing, check)
      |> load_form(FormState.form_from_check(check), FormState.vantage_points_from_inputs(inputs))
      |> assign(:rule_columns, RuleTable.columns(inputs))
      |> load_rules(check)
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

  defp load_inputs(check, scope) do
    case CompositeCheckInput.list_by_check(check.id, scope: scope) do
      {:ok, inputs} -> inputs
      {:error, _reason} -> []
    end
  end

  # Rules are read back from the resource rather than tracked in the form: every
  # edit is persisted immediately, so the loaded list is the only version of the
  # table that exists.
  defp load_rules(socket, check) do
    rules =
      case CompositeCheckRule.list_by_check(check.id, scope: socket.assigns.current_scope) do
        {:ok, rules} -> rules
        {:error, _reason} -> []
      end

    socket
    |> assign(:rules, rules)
    |> assign(:rule_error, nil)
    |> assign(:confirm_regenerate, false)
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

  # Generation is destructive to hand edits, so an existing authored table gets
  # a confirmation step. An empty table has nothing to lose and generates
  # straight away — a confirmation nobody can answer wrong is just a click.
  def handle_event("generate_rules", _params, socket) do
    cond do
      not socket.assigns.can_manage -> {:noreply, forbid(socket)}
      authored_rules(socket.assigns.rules) == [] -> {:noreply, regenerate(socket)}
      true -> {:noreply, assign(socket, :confirm_regenerate, true)}
    end
  end

  def handle_event("confirm_regenerate", _params, socket) do
    if socket.assigns.can_manage do
      {:noreply, regenerate(socket)}
    else
      {:noreply, forbid(socket)}
    end
  end

  def handle_event("cancel_regenerate", _params, socket) do
    {:noreply, assign(socket, :confirm_regenerate, false)}
  end

  def handle_event("update_rule", %{"rule_id" => id} = params, socket) do
    with true <- socket.assigns.can_manage,
         %{} = rule <- find_rule(socket, id) do
      {:noreply, apply_rule_update(socket, rule, params)}
    else
      false -> {:noreply, forbid(socket)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("move_rule", %{"id" => id, "direction" => direction}, socket) do
    if socket.assigns.can_manage do
      ordered = RuleTable.move(socket.assigns.rules, id, move_direction(direction))
      {:noreply, persist_positions(socket, ordered)}
    else
      {:noreply, forbid(socket)}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    with true <- socket.assigns.can_manage,
         %{} = rule <- find_rule(socket, id),
         # `Ash.destroy/2` returns a bare `:ok` unless the action returns the
         # destroyed record, so both shapes are the success case.
         :ok <- destroy_rules([rule], socket.assigns.current_scope) do
      {:noreply, load_rules(socket, socket.assigns.editing)}
    else
      false -> {:noreply, forbid(socket)}
      nil -> {:noreply, socket}
      {:error, error} -> {:noreply, assign(socket, :rule_error, FormState.error_message(error))}
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

  defp authored_rules(rules), do: Enum.reject(rules, & &1.catch_all)

  defp find_rule(socket, id), do: Enum.find(socket.assigns.rules, &(&1.id == id))

  defp move_direction("up"), do: :up
  defp move_direction(_direction), do: :down

  # Regeneration replaces the authored rows and leaves the catch-all alone. The
  # catch-all is created with the check and cannot be destroyed, so generating
  # must never try to produce one.
  defp regenerate(socket) do
    check = socket.assigns.editing
    scope = socket.assigns.current_scope
    inputs = load_inputs(check, scope)

    with :ok <- destroy_rules(authored_rules(socket.assigns.rules), scope),
         :ok <- create_rules(check, RuleGenerator.generate(inputs), scope) do
      socket
      |> assign(:rule_columns, RuleTable.columns(inputs))
      |> load_rules(check)
    else
      {:error, error} ->
        socket
        |> assign(:confirm_regenerate, false)
        |> assign(:rule_error, FormState.error_message(error))
    end
  end

  defp destroy_rules(rules, scope) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case Ash.destroy(rule, scope: scope) do
        :ok -> {:cont, :ok}
        {:ok, _destroyed} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create_rules(check, attrs_list, scope) do
    Enum.reduce_while(attrs_list, :ok, fn attrs, :ok ->
      CompositeCheckRule
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :check_id, check.id), scope: scope)
      |> Ash.create()
      |> case do
        {:ok, _rule} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # The catch-all takes `:relabel`, which is the only update its policy allows.
  # Routing it through `:update` would return Forbidden for an edit the UI does
  # offer, so the action is chosen from the rule, not from the form.
  defp apply_rule_update(socket, rule, params) do
    scope = socket.assigns.current_scope

    changeset =
      if rule.catch_all do
        Ash.Changeset.for_update(rule, :relabel, relabel_attrs(params), scope: scope)
      else
        Ash.Changeset.for_update(rule, :update, rule_attrs(socket, rule, params), scope: scope)
      end

    case Ash.update(changeset) do
      {:ok, _updated} -> load_rules(socket, socket.assigns.editing)
      {:error, error} -> assign(socket, :rule_error, FormState.error_message(error))
    end
  end

  # Only the fields the row actually submitted. A missing key means the form did
  # not render that control, and defaulting it to "" would blank a required
  # attribute rather than leave it alone.
  defp relabel_attrs(params) do
    Enum.reduce(
      %{verdict: "verdict", verdict_label: "verdict_label", verdict_description: "verdict_description"},
      %{},
      fn {attr, key}, acc ->
        case Map.fetch(params, key) do
          {:ok, value} -> Map.put(acc, attr, String.trim(to_string(value)))
          :error -> acc
        end
      end
    )
  end

  defp rule_attrs(socket, rule, params) do
    params
    |> relabel_attrs()
    |> Map.put(:status, params["status"])
    |> Map.put(:match, RuleTable.match_from_params(socket.assigns.rule_columns, params, rule.match))
  end

  defp persist_positions(socket, ordered) do
    scope = socket.assigns.current_scope

    ordered
    |> RuleTable.repositions()
    |> Enum.reduce_while(:ok, fn {rule, position}, :ok ->
      rule
      |> Ash.Changeset.for_update(:update, %{position: position}, scope: scope)
      |> Ash.update()
      |> case do
        {:ok, _updated} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      :ok -> load_rules(socket, socket.assigns.editing)
      {:error, error} -> assign(socket, :rule_error, FormState.error_message(error))
    end
  end

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

        <div :if={@editing} class="mt-6">
          <.rule_table
            rules={@rules}
            columns={@rule_columns}
            mode={if @editing == :new, do: :new, else: :edit}
            confirm_regenerate={@confirm_regenerate}
            error={@rule_error}
          />
        </div>

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
