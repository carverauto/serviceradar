defmodule ServiceRadarWebNGWeb.Api.SolutionPackController do
  @moduledoc """
  REST/JSON API controller for Solution Packs, Signed Release Catalogs, and
  Two-Way Private GitOps Sync (`/api/v2/catalog/*`) (`4.5`).

  Enforces RBAC permissions across operations:
  - `catalog.view` for listing/showing packs and repositories
  - `catalog.packs.install` for installing, upgrading, and importing `.srpack`/`.json` packs
  - `catalog.packs.export` for secret-free `.srpack`/`.json` exports
  - `catalog.repositories.manage` for creating, updating, deleting, and syncing repositories
  - `catalog.gitops.sync` for GitOps push/pull promotion and repository sync
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Catalog
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @view_permission "catalog.view"
  @install_permission "catalog.packs.install"
  @export_permission "catalog.packs.export"
  @manage_repos_permission "catalog.repositories.manage"
  @gitops_sync_permission "catalog.gitops.sync"

  def index(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_any_permission(conn, [@view_permission, @install_permission, @export_permission]) do
      case catalog_backend().list_packs(base_opts(conn)) do
        {:ok, packs} -> json(conn, %{data: packs})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def show(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_any_permission(conn, [@view_permission, @install_permission, @export_permission]),
         {:ok, slug} <- fetch_required_param(conn, params, "slug") do
      case catalog_backend().get_pack(slug, base_opts(conn)) do
        {:ok, pack} -> json(conn, %{data: pack})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def export(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @export_permission),
         {:ok, slug} <- fetch_required_param(conn, params, "slug"),
         {:ok, format} <- parse_export_format(params["format"]) do
      case catalog_backend().export_pack(slug, format, base_opts(conn)) do
        {:ok, bytes, filename} when is_binary(bytes) ->
          send_export_download(conn, bytes, filename, format)

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def export_custom(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @export_permission),
         {:ok, format} <- parse_export_format(params["format"]),
         {:ok, spec} <- extract_map_payload(params, ~w(spec pack data), "pack export spec is required") do
      case catalog_backend().export_custom_pack(spec, format, base_opts(conn)) do
        {:ok, bytes, filename} when is_binary(bytes) ->
          send_export_download(conn, bytes, filename, format)

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def install(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @install_permission),
         {:ok, slug} <- fetch_required_param(conn, params, "slug"),
         {:ok, dry_run} <- optional_boolean(params["dry_run"], false, "dry_run"),
         {:ok, install_paused} <-
           optional_boolean(params["install_paused"], false, "install_paused"),
         {:ok, activate_dashboards} <-
           optional_boolean(
             params["activate_dashboard_packages"],
             false,
             "activate_dashboard_packages"
           ) do
      reconcile_params =
        params
        |> Map.take(["config", "credential_bindings", "decisions", "source"])
        |> maybe_put_bool_param("activate_dashboard_packages", activate_dashboards)

      install_opts =
        conn
        |> base_opts()
        |> Keyword.put(:install_paused, install_paused)
        |> Keyword.put(:activate_dashboard_packages, activate_dashboards)

      result =
        if dry_run do
          catalog_backend().preview_install(slug, reconcile_params, install_opts)
        else
          catalog_backend().install_pack(slug, reconcile_params, install_opts)
        end

      case result do
        {:ok, data} -> json(conn, %{data: json_safe(data)})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def import_pack(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @install_permission),
         {:ok, dry_run} <- optional_boolean(params["dry_run"], false, "dry_run"),
         {:ok, install_paused} <-
           optional_boolean(params["install_paused"], false, "install_paused"),
         {:ok, activate_dashboards} <-
           optional_boolean(
             params["activate_dashboard_packages"],
             false,
             "activate_dashboard_packages"
           ),
         {:ok, pack_input} <- extract_import_payload(params) do
      reconcile_params =
        params
        |> Map.take(["config", "credential_bindings", "decisions", "source"])
        |> maybe_put_bool_param("activate_dashboard_packages", activate_dashboards)

      install_opts =
        conn
        |> base_opts()
        |> Keyword.put(:install_paused, install_paused)
        |> Keyword.put(:activate_dashboard_packages, activate_dashboards)

      result =
        if dry_run do
          catalog_backend().preview_install(pack_input, reconcile_params, install_opts)
        else
          catalog_backend().install_pack(pack_input, reconcile_params, install_opts)
        end

      case result do
        {:ok, data} -> json(conn, %{data: json_safe(data)})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def uninstall(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @install_permission),
         {:ok, slug} <- fetch_required_param(conn, params, "slug"),
         {:ok, detach?} <- optional_boolean(params["detach"], false, "detach") do
      result =
        if detach? do
          catalog_backend().detach_pack(slug, base_opts(conn))
        else
          catalog_backend().uninstall_pack(slug, base_opts(conn))
        end

      case result do
        {:ok, data} -> json(conn, %{data: json_safe(data)})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def list_repositories(conn, _params) do
    with :ok <- require_authenticated(conn),
         :ok <-
           require_any_permission(conn, [
             @view_permission,
             @manage_repos_permission,
             @gitops_sync_permission
           ]) do
      case catalog_backend().list_repositories(base_opts(conn)) do
        {:ok, repos} -> json(conn, %{data: repos})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def create_repository(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_repos_permission),
         {:ok, attrs} <-
           extract_map_payload(params, ~w(repository data), "repository payload is required") do
      case catalog_backend().create_repository(attrs, base_opts(conn)) do
        {:ok, repo} ->
          conn
          |> put_status(:created)
          |> json(%{data: repo})

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def update_repository(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_repos_permission),
         {:ok, id} <- fetch_required_param(conn, params, "id"),
         {:ok, attrs} <-
           extract_map_payload(
             Map.delete(params, "id"),
             ~w(repository data),
             "repository payload is required"
           ) do
      case catalog_backend().update_repository(id, attrs, base_opts(conn)) do
        {:ok, repo} -> json(conn, %{data: repo})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def delete_repository(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_repos_permission),
         {:ok, id} <- fetch_required_param(conn, params, "id") do
      case catalog_backend().delete_repository(id, base_opts(conn)) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def sync_repository(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_any_permission(conn, [@manage_repos_permission, @gitops_sync_permission]),
         {:ok, id} <- fetch_required_param(conn, params, "id") do
      case catalog_backend().sync_repository(id, base_opts(conn)) do
        {:ok, summary} -> json(conn, %{data: summary})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def gitops_push(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @gitops_sync_permission),
         {:ok, id} <- fetch_required_param(conn, params, "id"),
         {:ok, payload} <- extract_gitops_push_payload(conn, params) do
      opts =
        base_opts(conn) ++
          if is_binary(params["commit_message"]) and params["commit_message"] != "",
            do: [commit_message: params["commit_message"]],
            else: []

      case catalog_backend().push_to_gitops(id, payload, opts) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def gitops_pull(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @gitops_sync_permission),
         {:ok, id} <- fetch_required_param(conn, params, "id"),
         {:ok, slug} <- fetch_required_string(params["slug"], "slug"),
         {:ok, dry_run} <- optional_boolean(params["dry_run"], true, "dry_run") do
      opts =
        conn
        |> base_opts()
        |> Keyword.put(:dry_run, dry_run)
        |> maybe_put_opt(:ref, params["ref"])
        |> maybe_put_opt(:params, Map.take(params, ["config", "credential_bindings", "decisions"]))

      case catalog_backend().pull_from_gitops(id, slug, opts) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  ## Private helpers

  defp catalog_backend do
    Application.get_env(:serviceradar_web_ng, :catalog_backend, Catalog)
  end

  defp base_opts(conn) do
    [scope: conn.assigns[:current_scope]]
  end

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      %{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthenticated}
    end
  end

  defp require_permission(conn, permission) do
    if RBAC.can?(conn.assigns[:current_scope], permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_any_permission(conn, permissions) do
    scope = conn.assigns[:current_scope]

    if Enum.any?(permissions, &RBAC.can?(scope, &1)) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp fetch_required_param(conn, params, key) do
    raw = Map.get(conn.path_params, key) || Map.get(params, key)
    fetch_required_string(raw, key)
  end

  defp fetch_required_string(raw, key) when is_binary(raw) do
    case String.trim(raw) do
      "" -> {:error, :invalid_request, "#{key} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_required_string(_, key), do: {:error, :invalid_request, "#{key} is required"}

  defp parse_export_format(nil), do: {:ok, :srpack}
  defp parse_export_format(""), do: {:ok, :srpack}
  defp parse_export_format("srpack"), do: {:ok, :srpack}
  defp parse_export_format("json"), do: {:ok, :json}

  defp parse_export_format(other),
    do: {:error, :invalid_request, "unsupported export format #{inspect(other)}; use srpack or json"}

  defp send_export_download(conn, bytes, filename, :srpack) do
    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{safe_filename(filename)}"))
    |> send_resp(:ok, bytes)
  end

  defp send_export_download(conn, bytes, filename, :json) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{safe_filename(filename)}"))
    |> send_resp(:ok, bytes)
  end

  # The path is the temp file Plug created for this upload; a request body
  # cannot supply a Plug.Upload struct.
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_import_payload(%{"file" => %Plug.Upload{path: path}}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, :invalid_request, "failed to read uploaded file: #{inspect(reason)}"}
    end
  end

  defp extract_import_payload(%{"archive_base64" => b64}) when is_binary(b64) do
    case Base.decode64(String.trim(b64)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_request, "archive_base64 must be valid base64"}
    end
  end

  defp extract_import_payload(%{"files" => files}) when is_map(files) and map_size(files) > 0 do
    {:ok, files}
  end

  defp extract_import_payload(_),
    do: {:error, :invalid_request, "import requires a file upload, archive_base64, or files map"}

  defp extract_gitops_push_payload(conn, params) do
    cond do
      is_map(params["files"]) and map_size(params["files"]) > 0 ->
        {:ok, params["files"]}

      is_binary(params["pack_slug"]) and String.trim(params["pack_slug"]) != "" ->
        case catalog_backend().build_push_payload(params["pack_slug"], %{}, base_opts(conn)) do
          {:ok, files} -> {:ok, files}
          {:error, reason} -> {:error, :invalid_request, format_error(reason)}
        end

      is_map(params["spec"]) ->
        {:ok, params["spec"]}

      true ->
        {:error, :invalid_request, "gitops push requires pack_slug, files map, or spec"}
    end
  end

  defp extract_map_payload(params, wrapper_keys, error_message) when is_map(params) do
    wrapped =
      Enum.find_value(wrapper_keys, fn k ->
        case Map.get(params, k) do
          map when is_map(map) -> map
          _ -> nil
        end
      end)

    cond do
      is_map(wrapped) -> {:ok, wrapped}
      map_size(params) > 0 -> {:ok, Map.delete(params, "format")}
      true -> {:error, :invalid_request, error_message}
    end
  end

  defp optional_boolean(nil, default, _name), do: {:ok, default}
  defp optional_boolean("", default, _name), do: {:ok, default}
  defp optional_boolean(val, _default, _name) when is_boolean(val), do: {:ok, val}
  defp optional_boolean("true", _default, _name), do: {:ok, true}
  defp optional_boolean("false", _default, _name), do: {:ok, false}
  defp optional_boolean("1", _default, _name), do: {:ok, true}
  defp optional_boolean("0", _default, _name), do: {:ok, false}
  defp optional_boolean(_val, _default, name), do: {:error, :invalid_request, "#{name} must be a boolean"}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_put_bool_param(params, key, true), do: Map.put(params, key, true)
  defp maybe_put_bool_param(params, _key, _false), do: params

  defp safe_filename(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end

  defp handle_auth_error(conn, {:error, :unauthenticated}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "authentication required"})
  end

  defp handle_auth_error(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
  end

  defp handle_domain_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp handle_domain_error(conn, %Forbidden{}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden"})
  end

  defp handle_domain_error(conn, %Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Exception.message(error)})
  end

  defp handle_domain_error(conn, {:branch_conflict, details}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "upstream branch conflict", details: details})
  end

  defp handle_domain_error(conn, {:version_already_published, details}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "dashboard package version already published", details: details})
  end

  defp handle_domain_error(conn, {:slug_in_use, details}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "dashboard route slug is already in use", details: details})
  end

  defp handle_domain_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: format_error(reason)})
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)

  defp json_safe(%DateTime{} = dt), do: dt
  defp json_safe(%NaiveDateTime{} = dt), do: dt
  defp json_safe(%Date{} = d), do: d
  defp json_safe(%Ash.NotLoaded{}), do: nil
  defp json_safe(%Ash.CiString{string: s}), do: s

  defp json_safe(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__lateral_join_source__, :calculations, :aggregates])
    |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(other), do: other
end
