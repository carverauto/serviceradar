defmodule ServiceRadarWebNG.AdminApi do
  @moduledoc """
  Client for admin API endpoints.

  Uses a configurable client module for HTTP or local (test) execution.
  """

  @type scope :: ServiceRadarWebNG.Accounts.Scope.t()

  @callback list_users(scope(), map()) :: {:ok, list()} | {:error, term()}
  @callback create_user(scope(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_user(scope(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback deactivate_user(scope(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback reactivate_user(scope(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback get_authorization_settings(scope()) :: {:ok, map()} | {:error, term()}
  @callback update_authorization_settings(scope(), map()) :: {:ok, map()} | {:error, term()}

  def list_users(scope, params \\ %{}) do
    client().list_users(scope, params)
  end

  def create_user(scope, attrs) do
    client().create_user(scope, attrs)
  end

  def update_user(scope, id, attrs) do
    client().update_user(scope, id, attrs)
  end

  def deactivate_user(scope, id) do
    client().deactivate_user(scope, id)
  end

  def reactivate_user(scope, id) do
    client().reactivate_user(scope, id)
  end

  def get_authorization_settings(scope) do
    client().get_authorization_settings(scope)
  end

  def update_authorization_settings(scope, attrs) do
    client().update_authorization_settings(scope, attrs)
  end

  defp client do
    Application.get_env(:serviceradar_web_ng, :admin_api_client, ServiceRadarWebNG.AdminApi.Http)
  end
end
