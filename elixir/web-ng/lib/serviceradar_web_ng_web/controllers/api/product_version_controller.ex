defmodule ServiceRadarWebNGWeb.Api.ProductVersionController do
  @moduledoc """
  `GET /api/admin/version`: the running ServiceRadar release, so CLI install
  helpers can fetch matching edge RPMs. Any authenticated caller may read it.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope

  @doc "GET /api/admin/version -> `{version: \"1.4.82\" | nil}`"
  def show(conn, _params) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        json(conn, %{version: release_version()})

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  @doc false
  def release_version do
    case System.get_env("SERVICERADAR_RELEASE_VERSION") do
      value when is_binary(value) ->
        case value |> String.trim() |> String.trim_leading("v") do
          "" -> nil
          version -> version
        end

      _ ->
        nil
    end
  end
end
