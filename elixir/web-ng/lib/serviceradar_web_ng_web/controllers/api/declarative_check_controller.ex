defmodule ServiceRadarWebNGWeb.Api.DeclarativeCheckController do
  @moduledoc """
  REST/JSON API controller for declarative service and posture checks (`/api/v2/declarative-checks`).

  Enforces RBAC permissions across operations:
  - `declarative_checks.view` for list, show, and deterministic canonical export
  - `declarative_checks.manage` for create, update, delete, and validated import
  - `declarative_checks.evaluate` for bounded ephemeral test runs
  """

  use ServiceRadarWebNGWeb, :controller

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.DeclarativeChecks
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @view_permission "declarative_checks.view"
  @manage_permission "declarative_checks.manage"
  @evaluate_permission "declarative_checks.evaluate"

  @states %{
    "enabled" => :enabled,
    "draft" => :draft,
    "disabled" => :disabled
  }

  @test_run_option_keys ~w(target parameter_overrides edge_observations timeout_ms)

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @view_permission),
         {:ok, state} <- optional_state(params["state"]),
         {:ok, pack_id} <- optional_string(params["pack_id"], "pack_id") do
      opts =
        conn
        |> base_opts()
        |> Keyword.put(:state, state)
        |> Keyword.put(:pack_id, pack_id)

      case declarative_checks().list_checks(opts) do
        {:ok, checks} -> json(conn, %{data: checks})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def show(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @view_permission),
         {:ok, slug} <- fetch_slug(conn, params) do
      case declarative_checks().get_check(slug, base_opts(conn)) do
        {:ok, check} ->
          conn
          |> maybe_put_etag(check)
          |> json(%{data: check})

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, attrs} <- extract_check_attrs(params),
         {:ok, confirm_detach} <- optional_detach_flag(params, attrs) do
      opts = maybe_put_detach_opt(base_opts(conn), confirm_detach)

      case declarative_checks().create_check(attrs, opts) do
        {:ok, check} ->
          conn
          |> put_status(:created)
          |> maybe_put_etag(check)
          |> json(%{data: check})

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def update(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, slug} <- fetch_slug(conn, params),
         {:ok, attrs} <- extract_update_attrs(params),
         {:ok, confirm_detach} <- optional_detach_flag(params, attrs) do
      opts = maybe_put_detach_opt(base_opts(conn), confirm_detach)

      case declarative_checks().update_check(slug, attrs, opts) do
        {:ok, check} ->
          conn
          |> maybe_put_etag(check)
          |> json(%{data: check})

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def delete(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, slug} <- fetch_slug(conn, params) do
      case declarative_checks().delete_check(slug, base_opts(conn)) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def export(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @view_permission),
         {:ok, slug} <- fetch_slug(conn, params) do
      case declarative_checks().export_check_json(slug, base_opts(conn)) do
        {:ok, canonical_json} when is_binary(canonical_json) ->
          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{safe_filename(slug)}.declarative-check.json")
          )
          |> send_resp(:ok, canonical_json)

        {:error, error} ->
          handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def import_check(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @manage_permission),
         {:ok, dry_run} <- optional_boolean(params["dry_run"], false, "dry_run"),
         {:ok, force_overwrite} <-
           optional_boolean(params["force_overwrite"], false, "force_overwrite"),
         {:ok, allow_detach} <-
           optional_boolean(
             params["allow_detach"] || params["confirm_detach"],
             false,
             "allow_detach"
           ),
         {:ok, document} <- extract_import_document(params) do
      opts =
        conn
        |> base_opts()
        |> Keyword.put(:dry_run, dry_run)
        |> Keyword.put(:force_overwrite, force_overwrite)
        |> maybe_put_detach_opt(allow_detach)

      case declarative_checks().import_check(document, opts) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def test_run_inline(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @evaluate_permission),
         {:ok, document, run_params} <- extract_inline_test_run(params) do
      case declarative_checks().test_run(document, run_params, base_opts(conn)) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  def test_run(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @evaluate_permission),
         {:ok, slug} <- fetch_slug(conn, params),
         {:ok, run_params} <- extract_saved_test_run_params(params) do
      case declarative_checks().test_run(slug, run_params, base_opts(conn)) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, error} -> handle_domain_error(conn, error)
      end
    else
      {:error, :invalid_request, message} -> bad_request(conn, message)
      {:error, _reason} = error -> handle_auth_error(conn, error)
    end
  end

  defp fetch_slug(conn, params) do
    raw = Map.get(conn.path_params, "slug") || Map.get(params, "slug")

    case raw do
      slug when is_binary(slug) ->
        trimmed = String.trim(slug)

        if trimmed == "" do
          {:error, :invalid_request, "slug is required"}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_request, "slug is required"}
    end
  end

  defp extract_check_attrs(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp extract_check_attrs(%{"check" => check}) when is_map(check), do: {:ok, check}
  defp extract_check_attrs(%{"document" => doc}) when is_map(doc), do: {:ok, doc}
  defp extract_check_attrs(params) when is_map(params) and map_size(params) > 0, do: {:ok, params}

  defp extract_check_attrs(_), do: {:error, :invalid_request, "check document payload is required"}

  defp extract_update_attrs(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp extract_update_attrs(%{"check" => check}) when is_map(check), do: {:ok, check}
  defp extract_update_attrs(%{"document" => doc}) when is_map(doc), do: {:ok, doc}

  defp extract_update_attrs(params) when is_map(params) do
    {:ok, Map.delete(params, "slug")}
  end

  defp extract_import_document(%{"document" => doc}) when is_map(doc) or is_binary(doc) do
    {:ok, doc}
  end

  defp extract_import_document(%{"document" => _invalid}) do
    {:error, :invalid_request, "document must be a JSON object or string"}
  end

  defp extract_import_document(%{"json" => json}) when is_binary(json) do
    {:ok, json}
  end

  defp extract_import_document(params) when is_map(params) do
    cleaned = Map.drop(params, ["dry_run", "force_overwrite", "allow_detach", "confirm_detach"])

    if map_size(cleaned) == 0 do
      {:error, :invalid_request, "import document is required"}
    else
      {:ok, cleaned}
    end
  end

  defp extract_inline_test_run(params) when is_map(params) do
    run_params = Map.take(params, @test_run_option_keys)

    cond do
      is_map(params["document"]) ->
        {:ok, params["document"], run_params}

      is_map(params["check"]) ->
        {:ok, params["check"], run_params}

      map_size(Map.drop(params, @test_run_option_keys)) > 0 ->
        {:ok, Map.drop(params, @test_run_option_keys), run_params}

      true ->
        {:error, :invalid_request, "document is required for inline test-run"}
    end
  end

  defp extract_saved_test_run_params(params) when is_map(params) do
    {:ok, Map.take(params, @test_run_option_keys)}
  end

  defp optional_state(nil), do: {:ok, nil}
  defp optional_state(""), do: {:ok, nil}

  defp optional_state(value) when is_binary(value) do
    case Map.fetch(@states, value) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :invalid_request, "state must be one of: enabled, draft, disabled"}
    end
  end

  defp optional_state(_), do: {:error, :invalid_request, "state must be one of: enabled, draft, disabled"}

  defp optional_string(nil, _name), do: {:ok, nil}
  defp optional_string("", _name), do: {:ok, nil}
  defp optional_string(value, _name) when is_binary(value), do: {:ok, String.trim(value)}
  defp optional_string(_, name), do: {:error, :invalid_request, "#{name} must be a string"}

  defp optional_boolean(nil, default, _name), do: {:ok, default}
  defp optional_boolean(value, _default, _name) when is_boolean(value), do: {:ok, value}
  defp optional_boolean("true", _default, _name), do: {:ok, true}
  defp optional_boolean("false", _default, _name), do: {:ok, false}

  defp optional_boolean(_value, _default, name), do: {:error, :invalid_request, "#{name} must be a boolean"}

  defp optional_detach_flag(params, attrs) do
    raw =
      cond do
        Map.has_key?(attrs, "confirm_detach") -> attrs["confirm_detach"]
        Map.has_key?(attrs, "allow_detach") -> attrs["allow_detach"]
        Map.has_key?(params, "confirm_detach") -> params["confirm_detach"]
        Map.has_key?(params, "allow_detach") -> params["allow_detach"]
        true -> nil
      end

    optional_boolean(raw, false, "confirm_detach")
  end

  defp maybe_put_detach_opt(opts, true),
    do: opts |> Keyword.put(:confirm_detach, true) |> Keyword.put(:allow_detach, true)

  defp maybe_put_detach_opt(opts, false), do: opts

  defp maybe_put_etag(conn, %{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "" do
    put_resp_header(conn, "etag", ~s("#{updated_at}"))
  end

  defp maybe_put_etag(conn, _check), do: conn

  defp safe_filename(slug) do
    String.replace(slug, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: message})
  end

  defp handle_auth_error(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", message: "Authentication required"})
  end

  defp handle_auth_error(conn, {:error, {:forbidden, permission}}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "forbidden",
      message: "Missing required permission: #{permission}"
    })
  end

  defp handle_domain_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found", message: "Declarative check not found"})
  end

  defp handle_domain_error(_conn, %Forbidden{} = error), do: {:error, error}

  defp handle_domain_error(conn, %{kind: :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "forbidden", message: "You do not have permission to perform this action"})
  end

  defp handle_domain_error(conn, :managed_detach_confirmation_required) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "managed_detach_confirmation_required",
      kind: "managed_conflict",
      message: "Structural edits to a managed check require confirm_detach: true to detach from pack management",
      errors: [
        %{
          path: "$.managed",
          code: "managed_detach_confirmation_required",
          message: "Structural edits to a managed check require confirm_detach: true to detach from pack management"
        }
      ]
    })
  end

  defp handle_domain_error(conn, %{kind: kind, errors: errors}) when is_list(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: error_code_for_kind(kind),
      kind: to_string(kind),
      errors: Enum.map(errors, &normalize_issue/1)
    })
  end

  defp handle_domain_error(conn, %Invalid{} = error) do
    if managed_detach_ash_error?(error) do
      handle_domain_error(conn, :managed_detach_confirmation_required)
    else
      {:error, error}
    end
  end

  defp handle_domain_error(_conn, other), do: {:error, other}

  defp managed_detach_ash_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn err ->
      msg = Map.get(err, :message)
      is_binary(msg) and String.contains?(msg, "managed_detach_confirmation_required")
    end)
  end

  defp managed_detach_ash_error?(_), do: false

  defp error_code_for_kind(:secret_guard), do: "secret_guard_violation"
  defp error_code_for_kind("secret_guard"), do: "secret_guard_violation"
  defp error_code_for_kind(:schema_validation), do: "schema_validation_failed"
  defp error_code_for_kind("schema_validation"), do: "schema_validation_failed"
  defp error_code_for_kind(:invalid_json), do: "invalid_json"
  defp error_code_for_kind("invalid_json"), do: "invalid_json"
  defp error_code_for_kind(other), do: to_string(other)

  defp normalize_issue(issue) when is_map(issue) do
    %{
      path: Map.get(issue, :path) || Map.get(issue, "path") || "$",
      code: to_string(Map.get(issue, :code) || Map.get(issue, "code") || "validation_error"),
      message: Map.get(issue, :message) || Map.get(issue, "message") || "Validation error"
    }
  end

  defp normalize_issue(other) do
    %{path: "$", code: "validation_error", message: inspect(other)}
  end

  defp base_opts(conn) do
    scope = get_scope(conn)

    opts = [scope: scope]

    case conn.assigns[:ash_actor] do
      nil -> opts
      actor -> Keyword.put(opts, :actor, actor)
    end
  end

  defp declarative_checks do
    Application.get_env(:serviceradar_web_ng, :declarative_checks, DeclarativeChecks)
  end

  defp get_scope(conn), do: conn.assigns[:current_scope]

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]

    if RBAC.can?(scope, permission) do
      :ok
    else
      {:error, {:forbidden, permission}}
    end
  end
end
