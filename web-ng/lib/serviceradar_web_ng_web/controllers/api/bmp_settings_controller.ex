defmodule ServiceRadarWebNG.Api.BmpSettingsController do
  @moduledoc """
  JSON API controller for BMP settings management.
  """

  use ServiceRadarWebNGWeb, :controller

  use Permit.Phoenix.Controller,
    authorization_module: ServiceRadarWebNG.Authorization,
    resource_module: ServiceRadar.Observability.BmpSettings

  require Ash.Query

  alias ServiceRadar.Observability.BmpSettings
  alias ServiceRadar.Observability.BmpSettingsRuntime

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  GET /api/admin/bmp-settings
  """
  def show(conn, _params) do
    scope = conn.assigns.current_scope

    case get_or_create_settings(scope) do
      {:ok, settings} -> json(conn, settings_to_json(settings))
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  PUT /api/admin/bmp-settings
  """
  def update(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, settings} <- get_or_create_settings(scope),
         {:ok, attrs} <- normalize_attrs(params) do
      settings
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
      |> case do
        {:ok, updated} ->
          _ = BmpSettings.apply_routing_retention_policy(updated)
          _ = BmpSettingsRuntime.force_refresh()
          json(conn, settings_to_json(updated))

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, {:invalid_integer, field}} ->
        return_error(conn, :bad_request, "#{field} must be an integer")

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_or_create_settings(scope) do
    case BmpSettings
         |> Ash.Query.for_read(:get_singleton, %{}, scope: scope)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} ->
        BmpSettings
        |> Ash.Changeset.for_create(:create, %{}, scope: scope)
        |> Ash.create(scope: scope)

      {:ok, settings} ->
        {:ok, settings}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_attrs(params) when is_map(params) do
    fields = [
      {"bmp_routing_retention_days", :bmp_routing_retention_days},
      {"bmp_ocsf_min_severity", :bmp_ocsf_min_severity},
      {"god_view_causal_overlay_window_seconds", :god_view_causal_overlay_window_seconds},
      {"god_view_causal_overlay_max_events", :god_view_causal_overlay_max_events},
      {"god_view_routing_causal_severity_threshold", :god_view_routing_causal_severity_threshold}
    ]

    Enum.reduce_while(fields, {:ok, %{}}, fn {key, attr}, {:ok, acc} ->
      case Map.fetch(params, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case int_param(value) do
            {:ok, int} -> {:cont, {:ok, Map.put(acc, attr, int)}}
            {:error, :invalid_integer} -> {:halt, {:error, {:invalid_integer, key}}}
          end
      end
    end)
  end

  defp int_param(value) when is_integer(value), do: {:ok, value}

  defp int_param(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end

  defp int_param(_), do: {:error, :invalid_integer}

  @impl true
  def skip_preload do
    [:show, :update]
  end

  @impl true
  def fetch_subject(%{assigns: %{current_scope: %{user: user}}}) when not is_nil(user), do: user
  def fetch_subject(_conn), do: :anonymous

  @impl true
  def handle_unauthorized(_action, conn) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ServiceRadarWebNGWeb.ErrorJSON)
    |> render(:"403")
    |> halt()
  end

  defp settings_to_json(settings) do
    %{
      bmp_routing_retention_days: settings.bmp_routing_retention_days,
      bmp_ocsf_min_severity: settings.bmp_ocsf_min_severity,
      god_view_causal_overlay_window_seconds: settings.god_view_causal_overlay_window_seconds,
      god_view_causal_overlay_max_events: settings.god_view_causal_overlay_max_events,
      god_view_routing_causal_severity_threshold:
        settings.god_view_routing_causal_severity_threshold
    }
  end

  defp return_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
