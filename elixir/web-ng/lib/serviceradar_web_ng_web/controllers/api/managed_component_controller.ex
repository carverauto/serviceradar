defmodule ServiceRadarWebNGWeb.Api.ManagedComponentController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.ComponentCertificateAuthority, as: Authority
  alias ServiceRadar.Edge.ManagedCertificateLifecycle, as: Lifecycle
  alias ServiceRadar.Edge.ManagedComponentRegistration
  alias ServiceRadarWebNG.Edge.ManagedComponentConfiguration
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  def bootstrap(conn, _params) do
    with :ok <- authorize(conn), {:ok, key} <- Authority.policy_public_key() do
      readiness =
        case nats_rpc(:readiness, []) do
          %{ready: _} = value -> value
          _ -> %{auth_mode: nil, ready: false, reason: "core_unavailable"}
        end

      json(conn, %{data: %{policy_public_key: key, nats: readiness}})
    end
  end

  def bootstrap_nats(conn, params) do
    with :ok <- authorize(conn),
         account when is_binary(account) and byte_size(account) in 1..128 <- params["account_name"],
         {:ok, configuration} <- nats_rpc(:bootstrap, [account, conn.assigns.current_scope.user]) do
      json(conn, %{data: configuration})
    else
      {:error, _} = error -> error_response(conn, error)
      _ -> conn |> put_status(:bad_request) |> json(%{error: "account_name_required"})
    end
  end

  def create(conn, params) do
    with :ok <- authorize(conn),
         {:ok, component} <- ManagedComponentRegistration.register(params, opts(conn)),
         {:ok, configuration} <- ManagedComponentConfiguration.build(component, opts(conn)),
         {:ok, operation} <- Lifecycle.current(component.component_id, opts(conn)) do
      conn |> put_status(:created) |> json(%{data: Map.merge(project(component, operation), configuration)})
    else
      error -> error_response(conn, error)
    end
  end

  def adopt(conn, params) do
    with :ok <- authorize(conn),
         {:ok, %{component: component, certificate: certificate}} <-
           Authority.adopt_existing_certificate(params, opts(conn)) do
      conn |> put_status(:created) |> json(%{data: adopted(component, certificate)})
    else
      error -> error_response(conn, error)
    end
  end

  def record_successor(conn, %{"id" => id} = params) do
    with :ok <- authorize(conn),
         {:ok, %{component: component, certificate: certificate}} <-
           Authority.record_infrastructure_successor(id, params, opts(conn)) do
      conn |> put_status(:created) |> json(%{data: adopted(component, certificate)})
    else
      error -> error_response(conn, error)
    end
  end

  def revoke_certificate(conn, %{"id" => id, "fingerprint" => fingerprint}) do
    with :ok <- authorize(conn),
         {:ok, _} <-
           Authority.revoke_component_certificate(id, fingerprint, "operator-request", opts(conn)) do
      show(conn, %{"id" => id})
    else
      error -> error_response(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {:ok, component} <- Lifecycle.component(id, opts(conn)),
         {:ok, operation} <- Lifecycle.current(id, opts(conn)) do
      json(conn, %{data: project(component, operation)})
    else
      error -> error_response(conn, error)
    end
  end

  def rotate(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {:ok, operation} <- Lifecycle.rotate(id, opts(conn)),
         {:ok, component} <- Lifecycle.component(id, opts(conn)) do
      conn |> put_status(:accepted) |> json(%{data: project(component, operation)})
    else
      error -> error_response(conn, error)
    end
  end

  def revoke(conn, %{"id" => id}) do
    with :ok <- authorize(conn), {:ok, _} <- Authority.revoke_component(id, "operator-request", opts(conn)) do
      show(conn, %{"id" => id})
    else
      error -> error_response(conn, error)
    end
  end

  def reenroll(conn, %{"id" => id}) do
    with :ok <- authorize(conn), {:ok, _} <- Authority.reenroll_component(id, opts(conn)) do
      show(conn, %{"id" => id})
    else
      error -> error_response(conn, error)
    end
  end

  defp adopted(component, certificate) do
    %{
      component_id: component.component_id,
      service: component.component_type,
      host_agent_id: component.host_agent_id,
      partition_id: component.partition_id,
      generation: component.generation,
      blocked: component.blocked,
      server_hosts: component.server_hosts,
      nats_permissions: component.nats_permissions,
      certificate: %{
        fingerprint: certificate.fingerprint,
        issuer_fingerprint: certificate.issuer_fingerprint,
        serial_number: certificate.serial_number,
        not_before: DateTime.to_iso8601(certificate.not_before),
        not_after: DateTime.to_iso8601(certificate.not_after),
        role: certificate.role
      }
    }
  end

  defp project(component, operation) do
    lifecycle =
      if operation do
        %{
          operation_id: operation.id,
          generation: operation.generation,
          status: operation.status,
          installed: operation.receipt["installed"] == true,
          activated: operation.receipt["activated"] == true,
          renew_after: operation.renew_after,
          error: operation.error,
          enforcement_status: "unconfirmed"
        }
      else
        %{status: "registered", installed: false, activated: false, renew_after: nil, enforcement_status: "unconfirmed"}
      end

    %{
      component_id: component.component_id,
      service: component.component_type,
      host_agent_id: component.host_agent_id,
      partition_id: component.partition_id,
      generation: component.generation,
      blocked: component.blocked,
      server_hosts: component.server_hosts,
      lifecycle: lifecycle
    }
  end

  defp opts(conn), do: [scope: conn.assigns.current_scope]

  defp authorize(conn) do
    if RBAC.can?(conn.assigns[:current_scope], "settings.edge.manage"), do: :ok, else: {:error, :forbidden}
  end

  defp error_response(conn, {:error, reason})
       when is_atom(reason) and reason not in [:forbidden, :unauthorized, :not_found] do
    conn |> put_status(:conflict) |> json(%{error: Atom.to_string(reason)})
  end

  defp error_response(conn, {:error, {:agent_offline, _}}),
    do: conn |> put_status(:conflict) |> json(%{error: "host_agent_offline"})

  defp error_response(_conn, error), do: error

  defp nats_rpc(action, args) do
    manager = ServiceRadar.NATS.ManagedCertificateAuthorization

    case Enum.find([Node.self() | Node.list()], fn node ->
           is_pid(:rpc.call(node, Process, :whereis, [manager], 2_000))
         end) do
      nil ->
        {:error, :core_unavailable}

      node ->
        module = if action == :bootstrap, do: ServiceRadar.NATS.ManagedCertificateConfiguration, else: manager

        case :rpc.call(node, module, action, args, 10_000) do
          {:badrpc, _} -> {:error, :core_unavailable}
          result -> result
        end
    end
  end
end
