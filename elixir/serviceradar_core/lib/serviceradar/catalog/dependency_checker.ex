defmodule ServiceRadar.Catalog.DependencyChecker do
  @moduledoc """
  Verifies Solution Pack dependencies (`plugin_dependencies`,
  `worker_dependencies`, and `dashboard_package_dependencies`) against runtime
  control-plane state.

  Enforces the hard capability boundary:
  - Solution Pack installation NEVER auto-approves `:staged` Wasm plugin packages
    (`review_path`: `/settings/agents/plugins`).
  - Required `worker_dependencies` without a healthy compatible worker and
    without a `fallback_runner` block active pipeline installation (`paused`
    install_state remains available).
  - Required `dashboard_package_dependencies` require an `:enabled` matching
    `DashboardPackage` (or surface `/settings/dashboards/packages` for approval).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.VantageWorkerRegistration
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @plugins_review_path "/settings/agents/plugins"
  @dashboards_review_path "/settings/dashboards/packages"

  @type dependency_status :: %{
          package_id: String.t(),
          version_constraint: String.t(),
          required: boolean(),
          status: :satisfied | :staged_approval_required | :missing,
          matched_version: String.t() | nil,
          review_path: String.t() | nil,
          message: String.t()
        }

  @doc """
  Evaluates either a `plugin_dependencies` list (`[map()]`, preserving legacy
  callers) or a full Solution Pack manifest map (`plugin_dependencies`,
  `worker_dependencies`, `dashboard_package_dependencies`).

  Supports optional injectable loaders in `opts` for DB-free unit testing:
  - `:plugin_packages_loader` (`(package_id -> [map()])`)
  - `:worker_registrations_loader` (`(capability -> [map()])`)
  - `:dashboard_packages_loader` (`(dashboard_id -> [map()])`)
  """
  @spec check(map() | [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def check(manifest_or_deps, opts \\ [])

  def check(%{} = manifest, opts) when is_list(opts) do
    plugin_deps =
      Map.get(manifest, "plugin_dependencies") || Map.get(manifest, :plugin_dependencies) || []

    worker_deps =
      Map.get(manifest, "worker_dependencies") || Map.get(manifest, :worker_dependencies) || []

    dashboard_deps =
      Map.get(manifest, "dashboard_package_dependencies") ||
        Map.get(manifest, :dashboard_package_dependencies) || []

    plugin_results = Enum.map(List.wrap(plugin_deps), &evaluate_dependency(&1, opts))
    worker_results = Enum.map(List.wrap(worker_deps), &evaluate_worker_dependency(&1, opts))

    dashboard_results =
      Enum.map(List.wrap(dashboard_deps), &evaluate_dashboard_dependency(&1, opts))

    blocking_plugins =
      Enum.filter(plugin_results, fn res -> res.required and res.status != :satisfied end)

    blocking_workers =
      Enum.filter(worker_results, fn res -> res.blocking? end)

    blocking_dashboards =
      Enum.filter(dashboard_results, fn res -> res.required and res.status != :satisfied end)

    blocking_count =
      length(blocking_plugins) + length(blocking_workers) + length(blocking_dashboards)

    {:ok,
     %{
       ready?: blocking_count == 0,
       blocking_count: blocking_count,
       review_path: @plugins_review_path,
       dashboards_review_path: @dashboards_review_path,
       dependencies: plugin_results,
       worker_dependencies: worker_results,
       dashboard_package_dependencies: dashboard_results
     }}
  end

  def check(deps, opts) when is_list(deps) and is_list(opts) do
    results = Enum.map(deps, &evaluate_dependency(&1, opts))

    blocking =
      Enum.filter(results, fn res ->
        res.required and res.status != :satisfied
      end)

    {:ok,
     %{
       ready?: blocking == [],
       blocking_count: length(blocking),
       review_path: @plugins_review_path,
       dashboards_review_path: @dashboards_review_path,
       dependencies: results,
       worker_dependencies: [],
       dashboard_package_dependencies: []
     }}
  end

  def check(_other, _opts),
    do:
      {:ok,
       %{
         ready?: true,
         blocking_count: 0,
         review_path: @plugins_review_path,
         dashboards_review_path: @dashboards_review_path,
         dependencies: [],
         worker_dependencies: [],
         dashboard_package_dependencies: []
       }}

  defp evaluate_dependency(dep, opts) when is_map(dep) do
    pkg_id =
      to_string(
        Map.get(dep, "package_id") || Map.get(dep, :package_id) ||
          Map.get(dep, "plugin_id") || Map.get(dep, :plugin_id) || ""
      )

    constraint =
      to_string(
        Map.get(dep, "version_constraint") || Map.get(dep, :version_constraint) || ">= 0.0.0"
      )

    required? = Map.get(dep, "required", Map.get(dep, :required, true)) != false
    packages = load_packages(pkg_id, opts)

    matching =
      packages
      |> Enum.filter(&version_matches?(&1, constraint))
      |> sort_versions_desc()

    approved = Enum.find(matching, &(normalize_status(&1) == :approved))
    staged = Enum.find(matching, &(normalize_status(&1) == :staged))

    cond do
      not is_nil(approved) ->
        ver = pkg_version(approved)

        %{
          package_id: pkg_id,
          version_constraint: constraint,
          required: required?,
          status: :satisfied,
          matched_version: ver,
          review_path: nil,
          message: "Approved Wasm plugin #{pkg_id}@#{ver} satisfies #{constraint}"
        }

      not is_nil(staged) ->
        ver = pkg_version(staged)

        %{
          package_id: pkg_id,
          version_constraint: constraint,
          required: required?,
          status: :staged_approval_required,
          matched_version: ver,
          review_path: @plugins_review_path,
          message:
            "Plugin #{pkg_id}@#{ver} is staged and requires administrator capability approval at #{@plugins_review_path}"
        }

      true ->
        %{
          package_id: pkg_id,
          version_constraint: constraint,
          required: required?,
          status: :missing,
          matched_version: nil,
          review_path: @plugins_review_path,
          message:
            "No approved Wasm plugin package #{pkg_id} matching #{constraint}; stage and approve it at #{@plugins_review_path}"
        }
    end
  end

  defp evaluate_worker_dependency(dep, opts) when is_map(dep) do
    capability = to_string(Map.get(dep, "capability") || Map.get(dep, :capability) || "")

    min_proto =
      case Map.get(dep, "min_protocol_version") || Map.get(dep, :min_protocol_version) do
        val when is_binary(val) and val != "" -> val
        _ -> nil
      end

    optional? = Map.get(dep, "optional", Map.get(dep, :optional, false)) == true

    fallback_runner =
      case Map.get(dep, "fallback_runner") || Map.get(dep, :fallback_runner) do
        val when is_binary(val) and val != "" -> val
        val when is_atom(val) and not is_nil(val) -> Atom.to_string(val)
        _ -> nil
      end

    now = Keyword.get(opts, :now) || DateTime.utc_now()
    workers = load_worker_registrations(capability, now, opts)

    compatible_worker =
      Enum.find(workers, fn worker ->
        worker_healthy_and_active?(worker, capability, now) and
          protocol_version_satisfies?(
            Map.get(worker, :protocol_version) || Map.get(worker, "protocol_version"),
            min_proto
          )
      end)

    cond do
      not is_nil(compatible_worker) ->
        worker_id =
          Map.get(compatible_worker, :worker_id) || Map.get(compatible_worker, "worker_id")

        proto =
          Map.get(compatible_worker, :protocol_version) ||
            Map.get(compatible_worker, "protocol_version")

        %{
          capability: capability,
          min_protocol_version: min_proto,
          optional: optional?,
          fallback_runner: fallback_runner,
          required: not optional?,
          blocking?: false,
          fallback_available?: not is_nil(fallback_runner),
          status: :satisfied,
          matched_worker_id: worker_id,
          matched_protocol_version: proto,
          message:
            "Healthy worker #{inspect(worker_id)} provides #{capability} (#{proto || "v1"})"
        }

      not is_nil(fallback_runner) ->
        %{
          capability: capability,
          min_protocol_version: min_proto,
          optional: optional?,
          fallback_runner: fallback_runner,
          required: not optional?,
          blocking?: false,
          fallback_available?: true,
          status: :fallback_ready,
          matched_worker_id: nil,
          matched_protocol_version: nil,
          message: "No online worker for #{capability}; falling back to #{fallback_runner} runner"
        }

      true ->
        %{
          capability: capability,
          min_protocol_version: min_proto,
          optional: optional?,
          fallback_runner: nil,
          required: not optional?,
          blocking?: not optional?,
          fallback_available?: false,
          status: :missing,
          matched_worker_id: nil,
          matched_protocol_version: nil,
          message:
            if(optional?,
              do: "Optional Vantage worker #{capability} is offline",
              else:
                "Required Vantage worker capability #{capability}#{if(min_proto, do: " (>= #{min_proto})", else: "")} is missing and no fallback_runner is declared"
            )
        }
    end
  end

  defp evaluate_dashboard_dependency(dep, opts) when is_map(dep) do
    dashboard_id =
      to_string(
        Map.get(dep, "dashboard_id") || Map.get(dep, :dashboard_id) ||
          Map.get(dep, "id") || Map.get(dep, :id) || ""
      )

    constraint =
      to_string(
        Map.get(dep, "version_constraint") || Map.get(dep, :version_constraint) || ">= 0.0.0"
      )

    optional? = Map.get(dep, "optional", Map.get(dep, :optional, false)) == true
    required? = not optional?

    packages = load_dashboard_packages(dashboard_id, opts)

    matching =
      packages
      |> Enum.filter(&version_matches?(&1, constraint))
      |> sort_versions_desc()

    enabled = Enum.find(matching, &(normalize_dashboard_status(&1) == :enabled))
    staged = Enum.find(matching, &(normalize_dashboard_status(&1) in [:staged, :disabled]))

    cond do
      not is_nil(enabled) ->
        ver = pkg_version(enabled)

        %{
          dashboard_id: dashboard_id,
          version_constraint: constraint,
          required: required?,
          status: :satisfied,
          matched_version: ver,
          review_path: nil,
          message: "Enabled dashboard package #{dashboard_id}@#{ver} satisfies #{constraint}"
        }

      not is_nil(staged) ->
        ver = pkg_version(staged)

        %{
          dashboard_id: dashboard_id,
          version_constraint: constraint,
          required: required?,
          status: :staged_approval_required,
          matched_version: ver,
          review_path: @dashboards_review_path,
          message:
            "Dashboard package #{dashboard_id}@#{ver} is staged/disabled and requires approval at #{@dashboards_review_path}"
        }

      true ->
        %{
          dashboard_id: dashboard_id,
          version_constraint: constraint,
          required: required?,
          status: :missing,
          matched_version: nil,
          review_path: @dashboards_review_path,
          message:
            "No enabled dashboard package #{dashboard_id} matching #{constraint}; review at #{@dashboards_review_path}"
        }
    end
  end

  defp load_packages(pkg_id, opts) do
    case Keyword.get(opts, :plugin_packages_loader) do
      loader when is_function(loader, 1) ->
        List.wrap(loader.(pkg_id))

      _ ->
        if is_pid(Process.whereis(ServiceRadar.Repo)) do
          actor = Keyword.get(opts, :actor) || SystemActor.system(:catalog_dependency_checker)

          PluginPackage
          |> Ash.Query.for_read(:by_plugin_id, %{plugin_id: pkg_id}, actor: actor)
          |> Ash.read(actor: actor)
          |> case do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end
    end
  end

  defp load_worker_registrations(capability, now, opts) do
    case Keyword.get(opts, :worker_registrations_loader) do
      loader when is_function(loader, 1) ->
        List.wrap(loader.(capability))

      _ ->
        if is_pid(Process.whereis(ServiceRadar.Repo)) do
          actor = Keyword.get(opts, :actor) || SystemActor.system(:catalog_dependency_checker)

          case VantageWorkerRegistration.active_for_capability(capability, now, actor: actor) do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end
    end
  end

  defp load_dashboard_packages(dashboard_id, opts) do
    case Keyword.get(opts, :dashboard_packages_loader) do
      loader when is_function(loader, 1) ->
        List.wrap(loader.(dashboard_id))

      _ ->
        if is_pid(Process.whereis(ServiceRadar.Repo)) do
          actor = Keyword.get(opts, :actor) || SystemActor.system(:catalog_dependency_checker)

          DashboardPackage
          |> Ash.Query.for_read(:by_dashboard_id, %{dashboard_id: dashboard_id}, actor: actor)
          |> Ash.read(actor: actor)
          |> case do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end
    end
  end

  defp worker_healthy_and_active?(worker, capability, now) do
    health = Map.get(worker, :health) || Map.get(worker, "health")
    caps = Map.get(worker, :capabilities) || Map.get(worker, "capabilities") || []
    expires_at = Map.get(worker, :expires_at) || Map.get(worker, "expires_at")

    health_ok? = health in [:ready, "ready"]
    cap_ok? = capability in List.wrap(caps)

    not_expired? =
      case expires_at do
        %DateTime{} = dt -> DateTime.after?(dt, now)
        nil -> true
        _ -> false
      end

    health_ok? and cap_ok? and not_expired?
  end

  defp protocol_version_satisfies?(_actual, nil), do: true
  defp protocol_version_satisfies?(nil, _min), do: false

  defp protocol_version_satisfies?(actual, min_proto) do
    actual_str = to_string(actual)
    min_str = to_string(min_proto)

    case {Version.parse(actual_str), Version.parse(min_str)} do
      {{:ok, va}, {:ok, vb}} ->
        Version.compare(va, vb) in [:gt, :eq]

      _ ->
        case {extract_trailing_protocol_num(actual_str), extract_trailing_protocol_num(min_str)} do
          {{prefix_a, num_a}, {prefix_b, num_b}} when prefix_a == prefix_b ->
            num_a >= num_b

          _ ->
            actual_str == min_str
        end
    end
  end

  defp extract_trailing_protocol_num(str) do
    case Regex.run(~r/\A(.*?)(\d+)\z/, str) do
      [_, prefix, num_str] -> {prefix, String.to_integer(num_str)}
      _ -> nil
    end
  end

  defp normalize_dashboard_status(pkg) do
    case Map.get(pkg, :status) || Map.get(pkg, "status") do
      s when s in [:enabled, "enabled"] -> :enabled
      s when s in [:staged, "staged"] -> :staged
      s when s in [:disabled, "disabled"] -> :disabled
      s when s in [:revoked, "revoked"] -> :revoked
      _ -> :unknown
    end
  end

  defp version_matches?(pkg, constraint) do
    ver = pkg_version(pkg)

    with {:ok, parsed_ver} <- Version.parse(ver),
         {:ok, req} <- Version.parse_requirement(constraint) do
      Version.match?(parsed_ver, req)
    else
      _ -> false
    end
  end

  defp sort_versions_desc(pkgs) do
    Enum.sort(pkgs, fn a, b ->
      case {Version.parse(pkg_version(a)), Version.parse(pkg_version(b))} do
        {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) in [:gt, :eq]
        _ -> pkg_version(a) >= pkg_version(b)
      end
    end)
  end

  defp pkg_version(pkg) do
    to_string(Map.get(pkg, :version) || Map.get(pkg, "version") || "")
  end

  defp normalize_status(pkg) do
    case Map.get(pkg, :status) || Map.get(pkg, "status") do
      s when s in [:approved, "approved"] -> :approved
      s when s in [:staged, "staged"] -> :staged
      s when s in [:denied, "denied"] -> :denied
      s when s in [:revoked, "revoked"] -> :revoked
      _ -> :unknown
    end
  end
end
