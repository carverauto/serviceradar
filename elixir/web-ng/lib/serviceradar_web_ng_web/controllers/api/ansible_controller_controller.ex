defmodule ServiceRadarWebNGWeb.Api.AnsibleControllerController do
  @moduledoc """
  JSON API for AWX/AAP controller registration.

  Tokens are stored as credential secrets. This surface accepts secret ids only.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AnsibleControllers
  alias ServiceRadarWebNG.ConfigurationRequest
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @permission "ansible.controllers.manage"

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, controllers} <-
           ansible_controllers().list(scope: get_scope(conn), filters: params) do
      json(conn, Enum.map(controllers, &controller_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      case ansible_controllers().get(id, scope: get_scope(conn)) do
        {:ok, controller} -> render_controller(conn, controller)
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, attrs} <- normalize_attrs(params, partial: false) do
      result =
        ConfigurationRequest.create(
          conn,
          params,
          fn -> ansible_controllers().create(attrs, scope: get_scope(conn)) end,
          fn id -> ansible_controllers().get(id, scope: get_scope(conn)) end,
          required: false
        )

      case result do
        {:ok, controller} ->
          conn
          |> put_status(:created)
          |> render_controller(controller)

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      other ->
        other
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, opts} <- ConfigurationRequest.mutation_opts(conn, required: false),
         {:ok, attrs} <- normalize_attrs(params, partial: true) do
      case ansible_controllers().update(id, attrs, Keyword.put(opts, :scope, get_scope(conn))) do
        {:ok, controller} -> render_controller(conn, controller)
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      other ->
        other
    end
  end

  def enable(conn, %{"id" => id}) do
    set_enabled(conn, id, true)
  end

  def disable(conn, %{"id" => id}) do
    set_enabled(conn, id, false)
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, opts} <- ConfigurationRequest.mutation_opts(conn),
         {:ok, :ok} <- ansible_controllers().delete(id, Keyword.put(opts, :scope, get_scope(conn))) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} when reason in [:controller_in_use, :controller_must_be_disabled] ->
        conn |> put_status(:conflict) |> json(%{error: reason})

      error ->
        error
    end
  end

  def readiness(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, controller} <- ansible_controllers().get(id, scope: get_scope(conn)) do
      json(conn, %{
        controller_id: controller.id,
        enabled: controller.enabled,
        observed_health: controller.status,
        last_health_at: format_datetime(controller.last_health_at),
        credential_configuration: %{
          sync: not is_nil(controller.sync_credential_secret_id),
          execution: not is_nil(controller.execution_credential_secret_id),
          callback: not is_nil(controller.callback_credential_secret_id)
        },
        live_preflight_required: true
      })
    end
  end

  defp set_enabled(conn, id, enabled) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, opts} <- ConfigurationRequest.mutation_opts(conn, required: false) do
      case ansible_controllers().set_enabled(id, enabled, Keyword.put(opts, :scope, get_scope(conn))) do
        {:ok, controller} -> render_controller(conn, controller)
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp normalize_attrs(params, opts) do
    partial? = Keyword.get(opts, :partial, false)

    with {:ok, inventory_interval} <-
           optional_integer(
             params["inventory_sync_interval_seconds"],
             "inventory_sync_interval_seconds"
           ),
         {:ok, catalog_interval} <-
           optional_integer(
             params["catalog_sync_interval_seconds"],
             "catalog_sync_interval_seconds"
           ),
         {:ok, enabled} <- optional_boolean(params["enabled"], "enabled") do
      attrs =
        %{
          name: params["name"],
          description: params["description"],
          base_url: params["base_url"],
          agent_id: params["agent_id"],
          sync_credential_secret_id: params["sync_credential_secret_id"],
          execution_credential_secret_id: params["execution_credential_secret_id"],
          callback_credential_secret_id: params["callback_credential_secret_id"],
          inventory_sync_interval_seconds: inventory_interval,
          catalog_sync_interval_seconds: catalog_interval,
          enabled: enabled,
          metadata: params["metadata"]
        }
        |> Enum.reject(fn {key, value} ->
          is_nil(value) and
            (key not in [:execution_credential_secret_id, :callback_credential_secret_id] or
               not Map.has_key?(params, Atom.to_string(key)))
        end)
        |> Map.new()

      cond do
        not partial? and is_nil(attrs[:name]) ->
          {:error, :invalid_request, "name is required"}

        not partial? and is_nil(attrs[:base_url]) ->
          {:error, :invalid_request, "base_url is required"}

        not partial? and is_nil(attrs[:agent_id]) ->
          {:error, :invalid_request, "agent_id is required"}

        not partial? and is_nil(attrs[:sync_credential_secret_id]) ->
          {:error, :invalid_request, "sync_credential_secret_id is required"}

        true ->
          {:ok, attrs}
      end
    end
  end

  defp optional_integer(nil, _name), do: {:ok, nil}
  defp optional_integer(value, _name) when is_integer(value), do: {:ok, value}

  defp optional_integer(value, name) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_request, "#{name} must be an integer"}
    end
  end

  defp optional_integer(_value, name), do: {:error, :invalid_request, "#{name} must be an integer"}

  defp optional_boolean(nil, _name), do: {:ok, nil}
  defp optional_boolean(value, _name) when is_boolean(value), do: {:ok, value}
  defp optional_boolean("true", _name), do: {:ok, true}
  defp optional_boolean("false", _name), do: {:ok, false}
  defp optional_boolean(_value, name), do: {:error, :invalid_request, "#{name} must be a boolean"}

  defp controller_to_json(controller) do
    %{
      id: controller.id,
      name: controller.name,
      description: controller.description,
      base_url: controller.base_url,
      awx_version: controller.awx_version,
      agent_id: controller.agent_id,
      enabled: controller.enabled,
      sync_credential_secret_id: controller.sync_credential_secret_id,
      execution_credential_secret_id: controller.execution_credential_secret_id,
      callback_credential_secret_id: controller.callback_credential_secret_id,
      inventory_sync_interval_seconds: controller.inventory_sync_interval_seconds,
      catalog_sync_interval_seconds: controller.catalog_sync_interval_seconds,
      status: controller.status,
      last_health_at: format_datetime(controller.last_health_at),
      last_health_summary: controller.last_health_summary,
      metadata: controller.metadata || %{},
      inserted_at: format_datetime(controller.inserted_at),
      updated_at: format_datetime(controller.updated_at)
    }
  end

  defp render_controller(conn, controller) do
    conn |> ConfigurationRequest.put_etag(controller) |> json(controller_to_json(controller))
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp ansible_controllers do
    Application.get_env(:serviceradar_web_ng, :ansible_controllers, AnsibleControllers)
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
