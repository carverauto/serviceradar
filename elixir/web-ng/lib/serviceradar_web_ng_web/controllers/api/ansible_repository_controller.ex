defmodule ServiceRadarWebNGWeb.Api.AnsibleRepositoryController do
  @moduledoc """
  JSON lifecycle API for public HTTPS Git playbook repositories.

  Catalog synchronization never approves or launches a playbook. Credentials in
  URLs and private repository credentials are rejected until the catalog worker
  supports brokered Git authentication.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AnsibleRepositories
  alias ServiceRadarWebNG.ConfigurationRequest
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @write_fields ~w(name description git_url git_ref sync_interval_seconds credential_secret_id)
  @manage_permission "ansible.repositories.manage"
  @view_permission "ansible.catalog.view"

  def index(conn, params) do
    with :ok <- authorize(conn, @view_permission),
         {:ok, filters} <- normalize_filters(params),
         {:ok, page} <- repositories().list(scope(conn), filters) do
      json(conn, %{items: Enum.map(page.items, &repository_json/1), next_cursor: page.next_cursor})
    else
      error -> respond_error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- authorize(conn, @view_permission),
         {:ok, repository} <- repositories().get(scope(conn), id) do
      render_repository(conn, repository)
    else
      error -> respond_error(conn, error)
    end
  end

  def create(conn, params) do
    with :ok <- authorize(conn, @manage_permission),
         {:ok, attrs} <- normalize_attrs(params, false),
         {:ok, repository} <-
           ConfigurationRequest.create(
             conn,
             params,
             fn -> repositories().create(scope(conn), attrs) end,
             fn id -> repositories().get(scope(conn), id) end
           ) do
      conn |> put_status(:created) |> render_repository(repository)
    else
      error -> respond_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- authorize(conn, @manage_permission),
         {:ok, opts} <- ConfigurationRequest.mutation_opts(conn),
         {:ok, attrs} <- normalize_attrs(Map.delete(params, "id"), true),
         {:ok, repository} <- repositories().update(scope(conn), id, attrs, opts) do
      render_repository(conn, repository)
    else
      error -> respond_error(conn, error)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- authorize(conn, @manage_permission),
         {:ok, opts} <- ConfigurationRequest.mutation_opts(conn),
         {:ok, :ok} <- repositories().delete(scope(conn), id, opts) do
      send_resp(conn, :no_content, "")
    else
      error -> respond_error(conn, error)
    end
  end

  def sync(conn, %{"id" => id}) do
    with :ok <- authorize(conn, @manage_permission),
         {:ok, result} <- repositories().sync(scope(conn), id) do
      conn
      |> put_status(:accepted)
      |> json(Map.put(sync_json(result.repository), :scheduling_status, result.scheduling_status))
    else
      error -> respond_error(conn, error)
    end
  end

  def sync_status(conn, %{"id" => id}) do
    with :ok <- authorize(conn, @view_permission),
         {:ok, repository} <- repositories().get(scope(conn), id) do
      json(conn, sync_json(repository))
    else
      error -> respond_error(conn, error)
    end
  end

  defp normalize_attrs(params, partial?) do
    with :ok <- known_fields(params),
         :ok <- required_fields(params, partial?),
         :ok <- valid_strings(params),
         :ok <- valid_url(params),
         :ok <- valid_ref(params),
         :ok <- public_repository(params),
         {:ok, interval} <- sync_interval(params) do
      attrs =
        params
        |> Map.take(@write_fields)
        |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

      attrs =
        if Map.has_key?(params, "sync_interval_seconds"),
          do: Map.put(attrs, :sync_interval_seconds, interval),
          else: attrs

      {:ok, attrs}
    end
  end

  defp known_fields(params) do
    if Enum.all?(Map.keys(params), &(&1 in @write_fields)),
      do: :ok,
      else: invalid("request contains unsupported fields")
  end

  defp required_fields(_params, true), do: :ok

  defp required_fields(params, false) do
    if Map.has_key?(params, "name") and Map.has_key?(params, "git_url"),
      do: :ok,
      else: invalid("name and git_url are required")
  end

  defp valid_strings(params) do
    Enum.reduce_while([{"name", 255}, {"git_url", 4096}, {"git_ref", 255}, {"description", 4096}], :ok, fn {key, max},
                                                                                                           :ok ->
      case Map.fetch(params, key) do
        :error ->
          {:cont, :ok}

        {:ok, nil} when key == "description" ->
          {:cont, :ok}

        {:ok, value} when is_binary(value) and byte_size(value) in 1..max ->
          if String.trim(value) == value and not String.contains?(value, <<0>>),
            do: {:cont, :ok},
            else: {:halt, invalid("#{key} must be a non-empty string without surrounding whitespace")}

        _ ->
          {:halt, invalid("#{key} must be a non-empty string of at most #{max} bytes")}
      end
    end)
  end

  defp valid_url(%{"git_url" => value}) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        :ok

      _ ->
        invalid("git_url must be HTTPS without credentials, query parameters, or a fragment")
    end
  end

  defp valid_url(_), do: :ok

  defp valid_ref(%{"git_ref" => value}) do
    if Regex.match?(~r/[\s\x00-\x1f\x7f~^:?*\[\\]/, value) or
         String.contains?(value, ["..", "@{", "//"]) or
         String.starts_with?(value, ["-", "/", "."]) or
         String.ends_with?(value, ["/", ".", ".lock"]) do
      invalid("git_ref must be a Git branch or tag name")
    else
      :ok
    end
  end

  defp valid_ref(_), do: :ok

  defp public_repository(%{"credential_secret_id" => value}) when not is_nil(value),
    do: invalid("private Git repository authentication is not supported by the catalog worker")

  defp public_repository(_), do: :ok

  defp sync_interval(%{"sync_interval_seconds" => value}) when is_integer(value) and value >= 60,
    do: {:ok, value}

  defp sync_interval(%{"sync_interval_seconds" => _}),
    do: invalid("sync_interval_seconds must be an integer of at least 60")

  defp sync_interval(_), do: {:ok, nil}

  defp normalize_filters(params) do
    with {:ok, limit} <- page_limit(Map.get(params, "limit", 200)),
         {:ok, after_id} <- cursor(params["after"]) do
      {:ok, %{limit: limit, after: after_id}}
    end
  end

  defp page_limit(value) when is_integer(value) and value in 1..500, do: {:ok, value}

  defp page_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> page_limit(number)
      _ -> invalid("limit must be an integer between 1 and 500")
    end
  end

  defp page_limit(_), do: invalid("limit must be an integer between 1 and 500")
  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> invalid("after must be a repository UUID")
    end
  end

  defp render_repository(conn, repository) do
    conn |> ConfigurationRequest.put_etag(repository) |> json(repository_json(repository))
  end

  defp repository_json(repository) do
    %{
      id: repository.id,
      name: repository.name,
      description: repository.description,
      git_url: public_url(repository.git_url),
      git_ref: repository.git_ref,
      credential_secret_id: repository.credential_secret_id,
      sync_interval_seconds: repository.sync_interval_seconds,
      last_sync_status: repository.last_sync_status,
      last_sync_at: datetime(repository.last_sync_at),
      inserted_at: datetime(repository.inserted_at),
      updated_at: datetime(repository.updated_at)
    }
  end

  defp sync_json(repository) do
    %{
      repository_id: repository.id,
      status: repository.last_sync_status,
      last_sync_at: datetime(repository.last_sync_at),
      private_auth_supported: false,
      diagnostic_count: map_size(repository.parse_diagnostics || %{})
    }
  end

  # Historical registrations may contain userinfo. It must never become API
  # output, Terraform state, or an error diagnostic.
  defp public_url(url) do
    case URI.new(url) do
      {:ok, uri} -> URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
      _ -> nil
    end
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp authorize(conn, permission) do
    case scope(conn) do
      %Scope{user: user} = scope when not is_nil(user) ->
        if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp respond_error(conn, {:error, :invalid_request, message}),
    do: conn |> put_status(:bad_request) |> json(%{error: "invalid_request", message: message})

  defp respond_error(conn, {:error, reason}) when reason in [:repository_in_use, :conflict],
    do: conn |> put_status(:conflict) |> json(%{error: reason})

  defp respond_error(conn, {:error, :precondition_required}),
    do: conn |> put_status(428) |> json(%{error: "precondition_required"})

  defp respond_error(conn, {:error, :invalid_precondition}),
    do: conn |> put_status(:bad_request) |> json(%{error: "invalid_precondition"})

  defp respond_error(_conn, error), do: error
  defp invalid(message), do: {:error, :invalid_request, message}
  defp scope(conn), do: conn.assigns[:current_scope]

  defp repositories do
    Application.get_env(:serviceradar_web_ng, :ansible_repositories, AnsibleRepositories)
  end
end
