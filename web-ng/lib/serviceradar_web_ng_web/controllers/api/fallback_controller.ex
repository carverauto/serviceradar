defmodule ServiceRadarWebNG.Api.FallbackController do
  @moduledoc """
  Fallback controller for API error handling.

  Translates error tuples into appropriate HTTP responses.

  ## Ash Error Handling

  This controller handles Ash framework errors with appropriate HTTP status codes:

  - `Ash.Error.Forbidden` -> 403 Forbidden (policy authorization failure)
  - `Ash.Error.Invalid` -> 422 Unprocessable Entity (validation errors)
  - `Ash.Error.Query.NotFound` -> 404 Not Found

  Error messages are sanitized to prevent information leakage about
  authorization policies or internal state.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNGWeb.AuthorizationAudit

  require Logger

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"401")
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"403")
  end

  # Handle Ash authorization errors (policy failures)
  def call(conn, {:error, %Ash.Error.Forbidden{} = error}) do
    AuthorizationAudit.log_failure(conn, error)

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "forbidden",
      message: "You do not have permission to perform this action"
    })
  end

  # Handle Ash validation errors
  def call(conn, {:error, %Ash.Error.Invalid{} = error}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "validation_error",
      details: format_ash_errors(error)
    })
  end

  # Handle Ash not found errors
  def call(conn, {:error, %Ash.Error.Query.NotFound{}}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"404")
  end

  # Handle generic Ash errors (catch-all for other Ash error types)
  def call(conn, {:error, %{__struct__: struct} = error})
      when struct in [Ash.Error.Forbidden, Ash.Error.Invalid, Ash.Error.Unknown] do
    Logger.warning("Unhandled Ash error: #{inspect(error)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "internal_error", message: "An unexpected error occurred"})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "validation_error",
      details: format_changeset_errors(changeset)
    })
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: to_string(reason)})
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_ash_errors(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.map(fn error ->
      case error do
        %{field: field, message: message} when not is_nil(field) ->
          %{field: field, message: message}

        %{message: message} ->
          %{message: message}

        _ ->
          %{message: "Validation error"}
      end
    end)
  end

end
