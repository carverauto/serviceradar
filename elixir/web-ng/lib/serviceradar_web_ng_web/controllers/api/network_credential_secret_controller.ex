defmodule ServiceRadarWebNGWeb.Api.NetworkCredentialSecretController do
  @moduledoc """
  JSON API for reusable network credential secrets.

  Secret payloads are write-only. List and get responses never include
  plaintext or ciphertext.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.NetworkCredentials
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @permission "settings.credentials.manage"

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, secrets} <-
           credentials().list_secrets(scope: get_scope(conn), filters: params) do
      json(conn, Enum.map(secrets, &secret_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      case credentials().get_secret(id, scope: get_scope(conn)) do
        {:ok, secret} -> json(conn, secret_to_json(secret))
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      case credentials().create_secret(params, scope: get_scope(conn)) do
        {:ok, secret} ->
          conn
          |> put_status(:created)
          |> json(secret_to_json(secret))

        {:error, :invalid_request, message} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "invalid_request", message: message})

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      attrs = %{
        name: params["name"],
        description: params["description"]
      }

      case credentials().update_secret_details(id, attrs, scope: get_scope(conn)) do
        {:ok, secret} -> json(conn, secret_to_json(secret))
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def rotate(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      values = Map.get(params, "values") || %{}

      if is_map(values) do
        case credentials().rotate_secret(id, values, scope: get_scope(conn)) do
          {:ok, secret} ->
            json(conn, secret_to_json(secret))

          {:error, :invalid_request, message} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "invalid_request", message: message})

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, error} ->
            {:error, error}
        end
      else
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: "values must be an object"})
      end
    end
  end

  defp secret_to_json(secret) do
    %{
      id: secret.id,
      name: secret.name,
      description: secret.description,
      provider: secret.provider,
      credential_kind: secret.credential_kind,
      username: secret.username,
      public_fingerprint: secret.public_fingerprint,
      source_type: secret.source_type,
      rotation_state: secret.rotation_state,
      last_rotated_at: format_datetime(secret.last_rotated_at),
      next_rotation_due_at: format_datetime(Map.get(secret, :next_rotation_due_at)),
      metadata: public_metadata(secret.metadata),
      inserted_at: format_datetime(secret.inserted_at),
      updated_at: format_datetime(secret.updated_at)
    }
  end

  defp public_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, ["secret", "token", "password", "private_key"])
  end

  defp public_metadata(_), do: %{}

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp credentials do
    Application.get_env(:serviceradar_web_ng, :network_credentials, NetworkCredentials)
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
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
