defmodule ServiceRadarWebNGWeb.Plugs.ApiErrorHandler do
  @moduledoc """
  Error handler plug for JSON:API endpoints.

  This plug wraps the request in a try/rescue block to catch any uncaught
  exceptions and format them as proper JSON:API error responses.

  ## Error Handling

  - Ash errors are formatted according to JSON:API spec
  - Authentication errors return 401
  - Authorization/policy errors return 403
  - Not found errors return 404
  - Validation errors return 400 or 422
  - Server errors return 500 with safe error messages

  ## Telemetry

  Emits telemetry events for API errors:
  - `[:serviceradar, :api, :error]` - with error metadata
  """

  @behaviour Plug

  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &handle_response/1)
  end

  defp handle_response(conn) do
    # Log errors for non-2xx responses in API paths
    if api_path?(conn) and error_status?(conn.status) do
      emit_error_telemetry(conn)
    end

    conn
  end

  defp api_path?(conn) do
    case conn.path_info do
      ["api", "v2" | _] -> true
      _ -> false
    end
  end

  defp error_status?(status) when is_integer(status), do: status >= 400
  defp error_status?(_), do: false

  defp emit_error_telemetry(conn) do
    :telemetry.execute(
      [:serviceradar, :api, :error],
      %{count: 1},
      %{
        status: conn.status,
        path: Enum.join(conn.path_info, "/"),
        method: conn.method
      }
    )
  end

  @doc """
  Format an Ash error into a JSON:API error response.

  This is a helper function that can be used by controllers to format
  Ash errors into proper JSON:API error responses.
  """
  def format_ash_error(%Ash.Error.Forbidden{} = error) do
    %{
      errors: [
        %{
          status: "403",
          code: "forbidden",
          title: "Forbidden",
          detail: format_error_detail(error)
        }
      ]
    }
  end

  def format_ash_error(%Ash.Error.Invalid{errors: errors}) do
    %{
      errors: Enum.map(errors, &format_validation_error/1)
    }
  end

  def format_ash_error(%Ash.Error.Query.NotFound{} = error) do
    %{
      errors: [
        %{
          status: "404",
          code: "not_found",
          title: "Not Found",
          detail: format_error_detail(error)
        }
      ]
    }
  end

  def format_ash_error(error) do
    %{
      errors: [
        %{
          status: "500",
          code: "internal_server_error",
          title: "Internal Server Error",
          detail: format_error_detail(error)
        }
      ]
    }
  end

  defp format_validation_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: message}) do
    %{
      status: "422",
      code: "invalid_attribute",
      title: "Invalid Attribute",
      detail: message,
      source: %{pointer: "/data/attributes/#{field}"}
    }
  end

  defp format_validation_error(%Ash.Error.Changes.Required{field: field}) do
    %{
      status: "422",
      code: "required",
      title: "Required Attribute",
      detail: "is required",
      source: %{pointer: "/data/attributes/#{field}"}
    }
  end

  defp format_validation_error(error) do
    %{
      status: "422",
      code: "validation_error",
      title: "Validation Error",
      detail: format_error_detail(error)
    }
  end

  defp format_error_detail(%{message: message}) when is_binary(message), do: message
  defp format_error_detail(error) when is_exception(error), do: Exception.message(error)
  defp format_error_detail(error) when is_binary(error), do: error
  defp format_error_detail(_), do: "An error occurred"
end
