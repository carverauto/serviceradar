defmodule ServiceRadarWebNGWeb.Api.NetworkCredentialRuleController do
  @moduledoc """
  JSON API for network credential rules, including TLS policy and CA trust material.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.ConfigurationRequest
  alias ServiceRadarWebNG.NetworkCredentials
  alias ServiceRadarWebNG.RBAC

  action_fallback(ServiceRadarWebNGWeb.Api.FallbackController)

  @permission "settings.credentials.manage"
  @scope_types %{
    "agent" => :agent,
    "gateway" => :gateway,
    "partition" => :partition
  }
  @tls_policies %{"verify" => :verify, "skip_verify" => :skip_verify}
  @ssh_policies %{
    "known_hosts" => :known_hosts,
    "trust_on_first_use" => :trust_on_first_use,
    "skip_verify" => :skip_verify
  }

  def index(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, rules} <- credentials().list_rules(scope: get_scope(conn), filters: params) do
      json(conn, Enum.map(rules, &rule_to_json/1))
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission) do
      case credentials().get_rule(id, scope: get_scope(conn)) do
        {:ok, rule} -> rule_response(conn, rule)
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  def create(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, attrs} <- normalize_rule_attrs(params) do
      result =
        ConfigurationRequest.create(
          conn,
          params,
          fn -> credentials().create_rule(attrs, scope: get_scope(conn)) end,
          fn id -> credentials().get_rule(id, scope: get_scope(conn)) end,
          required: false
        )

      case result do
        {:ok, rule} ->
          conn
          |> put_status(:created)
          |> rule_response(rule)

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
         {:ok, attrs} <- normalize_rule_attrs(params, partial: true),
         {:ok, mutation_opts} <- ConfigurationRequest.mutation_opts(conn, required: false) do
      case credentials().update_rule(id, attrs, [scope: get_scope(conn)] ++ mutation_opts) do
        {:ok, rule} -> rule_response(conn, rule)
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
         :ok <- credentials().delete_rule(id, Keyword.put(opts, :scope, get_scope(conn))) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} when reason in [:credential_rule_must_be_disabled, :credential_rule_in_use] ->
        conn |> put_status(:conflict) |> json(%{error: reason})

      error ->
        error
    end
  end

  defp set_enabled(conn, id, enabled) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, @permission),
         {:ok, mutation_opts} <- ConfigurationRequest.mutation_opts(conn, required: false) do
      case credentials().set_rule_enabled(id, enabled, [scope: get_scope(conn)] ++ mutation_opts) do
        {:ok, rule} -> rule_response(conn, rule)
        {:error, :not_found} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp rule_response(conn, rule) do
    conn
    |> ConfigurationRequest.put_etag(rule)
    |> json(rule_to_json(rule))
  end

  defp normalize_rule_attrs(params, opts \\ []) do
    partial? = Keyword.get(opts, :partial, false)

    with {:ok, scope_type} <- optional_enum(params, "scope_type", @scope_types, partial?),
         {:ok, tls_policy} <- optional_enum(params, "tls_policy", @tls_policies, true),
         {:ok, ssh_policy} <- optional_enum(params, "ssh_host_key_policy", @ssh_policies, true),
         {:ok, allowed_ports} <- optional_ports(params["allowed_ports"]),
         {:ok, priority} <- optional_integer(params["priority"], "priority"),
         {:ok, enabled} <- optional_boolean(params["enabled"], "enabled") do
      attrs =
        %{
          name: params["name"],
          description: params["description"],
          provider: params["provider"],
          auth_method: params["auth_method"],
          purpose: params["purpose"],
          target_query: params["target_query"],
          scope_type: scope_type,
          scope_value: params["scope_value"],
          secret_id: params["secret_id"],
          allowed_ports: allowed_ports,
          tls_policy: tls_policy,
          ssh_host_key_policy: ssh_policy,
          ca_bundle_pem: params["ca_bundle_pem"],
          server_cert_fingerprint: params["server_cert_fingerprint"],
          priority: priority,
          enabled: enabled,
          metadata: params["metadata"]
        }
        |> Enum.reject(fn {key, value} ->
          is_nil(value) and
            (key not in [:description, :ca_bundle_pem, :server_cert_fingerprint] or
               not Map.has_key?(params, Atom.to_string(key)))
        end)
        |> Map.new()

      if partial? or Map.has_key?(attrs, :name) do
        {:ok, attrs}
      else
        {:error, :invalid_request, "name is required"}
      end
    end
  end

  defp optional_enum(params, key, allowed, optional?) do
    case Map.get(params, key) do
      nil when optional? ->
        {:ok, nil}

      nil ->
        {:error, :invalid_request, "#{key} is required"}

      value when is_atom(value) ->
        if value in Map.values(allowed),
          do: {:ok, value},
          else: {:error, :invalid_request, "invalid #{key}"}

      value when is_binary(value) ->
        case Map.fetch(allowed, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, :invalid_request, "invalid #{key}"}
        end

      _ ->
        {:error, :invalid_request, "invalid #{key}"}
    end
  end

  defp optional_ports(nil), do: {:ok, nil}

  defp optional_ports(ports) when is_list(ports) do
    if Enum.all?(ports, &(is_integer(&1) and &1 > 0 and &1 <= 65_535)) do
      {:ok, ports}
    else
      {:error, :invalid_request, "allowed_ports must be integers between 1 and 65535"}
    end
  end

  defp optional_ports(_), do: {:error, :invalid_request, "allowed_ports must be an array"}

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

  defp rule_to_json(rule) do
    %{
      id: rule.id,
      name: rule.name,
      description: rule.description,
      enabled: rule.enabled,
      priority: rule.priority,
      provider: rule.provider,
      auth_method: rule.auth_method,
      purpose: rule.purpose,
      target_query: rule.target_query,
      scope_type: rule.scope_type,
      scope_value: rule.scope_value,
      secret_id: rule.secret_id,
      allowed_ports: rule.allowed_ports,
      tls_policy: rule.tls_policy,
      ssh_host_key_policy: rule.ssh_host_key_policy,
      ca_bundle_pem: rule.ca_bundle_pem,
      server_cert_fingerprint: rule.server_cert_fingerprint,
      metadata: rule.metadata || %{},
      last_test_status: rule.last_test_status,
      last_tested_at: format_datetime(rule.last_tested_at),
      last_test_message: rule.last_test_message,
      inserted_at: format_datetime(rule.inserted_at),
      updated_at: format_datetime(rule.updated_at)
    }
  end

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
