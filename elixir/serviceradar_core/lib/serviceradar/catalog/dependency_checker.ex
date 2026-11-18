defmodule ServiceRadar.Catalog.DependencyChecker do
  @moduledoc """
  Verifies Solution Pack `plugin_dependencies` against `ServiceRadar.Plugins.PluginPackage`
  approval state (`2.5`, Decision 5, `wasm-plugin-system`).

  Enforces the hard capability boundary: Solution Pack installation NEVER
  auto-approves `:staged` Wasm plugin packages. Any required dependency that is
  missing or `:staged` awaiting capability review blocks active installation and
  surfaces the review path (`/settings/agents/plugins`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @plugins_review_path "/settings/agents/plugins"

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
  Evaluates a pack manifest's `plugin_dependencies` list and returns a structured
  readiness report (`%{ready?: boolean(), dependencies: [dependency_status()]}`).

  Supports an optional `:plugin_packages_loader` `(package_id -> [map()])` in
  `opts` for DB-free unit testing.
  """
  @spec check(map() | [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def check(manifest_or_deps, opts \\ [])

  def check(%{"plugin_dependencies" => deps}, opts) when is_list(deps) do
    check(deps, opts)
  end

  def check(%{plugin_dependencies: deps}, opts) when is_list(deps) do
    check(deps, opts)
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
       dependencies: results
     }}
  end

  def check(_other, _opts),
    do:
      {:ok,
       %{ready?: true, blocking_count: 0, review_path: @plugins_review_path, dependencies: []}}

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
