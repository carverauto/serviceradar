defmodule ServiceRadarWebNG.Api.NatsController do
  @moduledoc """
  JSON API controller for NATS platform bootstrap and administration.

  Provides REST endpoints for:
  - Platform NATS server bootstrap (operator setup)
  - Bootstrap token generation
  - NATS operator status
  - Tenant NATS account management
  """

  use ServiceRadarWebNGWeb, :controller

  require Ash.Query

  alias ServiceRadar.Infrastructure.NatsOperator
  alias ServiceRadar.Infrastructure.NatsPlatformToken
  alias ServiceRadar.NATS.AccountClient

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  POST /api/admin/nats/bootstrap-token

  Generates a one-time bootstrap token for NATS platform initialization.
  Requires super_admin role.
  """
  def generate_bootstrap_token(conn, params) do
    # Calculate expires_at from expires_in_seconds or default to 24 hours
    expires_in_seconds = params["expires_in_seconds"] || 86_400
    expires_at = DateTime.add(DateTime.utc_now(), expires_in_seconds, :second)

    case NatsPlatformToken
         |> Ash.Changeset.for_create(:generate, %{
           purpose: :nats_bootstrap,
           expires_at: expires_at
         })
         |> Ash.create(authorize?: false) do
      {:ok, token_record} ->
        conn
        |> put_status(:created)
        |> json(%{
          token: token_record.token_secret,
          expires_at: DateTime.to_iso8601(token_record.expires_at)
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/admin/nats/bootstrap

  Bootstraps the NATS operator for the platform.
  Requires a valid bootstrap token.

  Request body:
    - token: bootstrap token (required)
    - operator_name: name for the operator (optional, default: "serviceradar")
    - existing_operator_seed: import existing seed (optional)
    - generate_system_account: whether to generate system account (default: true)
  """
  def bootstrap(conn, params) do
    token = params["token"]
    operator_name = params["operator_name"] || "serviceradar"
    existing_seed = params["existing_operator_seed"]
    generate_system = Map.get(params, "generate_system_account", true)
    source_ip = get_client_ip(conn)

    with :ok <- validate_bootstrap_token(token, source_ip),
         {:ok, result} <- do_bootstrap(operator_name, existing_seed, generate_system) do
      json(conn, %{
        operator_public_key: result.operator_public_key,
        operator_seed: result.operator_seed,
        operator_jwt: result.operator_jwt,
        system_account_public_key: result.system_account_public_key,
        system_account_seed: result.system_account_seed,
        system_account_jwt: result.system_account_jwt
      })
    else
      {:error, :token_required} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "bootstrap token is required"})

      {:error, :token_invalid} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid or expired bootstrap token"})

      {:error, :already_initialized} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "NATS operator already initialized"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "bootstrap failed: #{inspect(reason)}"})
    end
  end

  @doc """
  GET /api/admin/nats/status

  Returns the current NATS operator status.
  """
  def status(conn, _params) do
    case get_current_operator() do
      {:ok, operator} ->
        json(conn, %{
          is_initialized: true,
          operator_name: operator.name,
          operator_public_key: operator.public_key,
          status: to_string(operator.status),
          bootstrapped_at: format_datetime(operator.bootstrapped_at)
        })

      {:error, :not_found} ->
        json(conn, %{
          is_initialized: false,
          operator_name: nil,
          operator_public_key: nil
        })
    end
  end

  @doc """
  GET /api/admin/nats/tenants

  Lists all tenant NATS accounts.
  Requires super_admin role.
  """
  def tenants(conn, params) do
    limit = parse_int(params["limit"]) || 50

    tenants =
      ServiceRadar.Identity.Tenant
      |> Ash.Query.for_read(:read)
      |> Ash.Query.select([:id, :slug, :name, :nats_account_status, :nats_account_public_key])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.read!(authorize?: false)

    json(conn, Enum.map(tenants, &tenant_to_json/1))
  end

  @doc """
  POST /api/admin/nats/tenants/:id/reprovision

  Retries provisioning for a failed tenant NATS account.
  """
  def reprovision(conn, %{"id" => tenant_id}) do
    case get_tenant(tenant_id) do
      {:ok, tenant} ->
        if tenant.nats_account_status in [:failed, :pending, :error] do
          # Re-enqueue the provisioning job
          case ServiceRadar.NATS.Workers.CreateAccountWorker.enqueue(tenant_id) do
            {:ok, _job} ->
              json(conn, %{
                tenant_id: tenant_id,
                status: "provisioning",
                message: "Reprovisioning job enqueued"
              })

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: "Failed to enqueue reprovisioning: #{inspect(reason)}"})
          end
        else
          conn
          |> put_status(:conflict)
          |> json(%{
            error: "Tenant NATS account is not in failed or pending state",
            current_status: to_string(tenant.nats_account_status)
          })
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Private helpers

  defp validate_bootstrap_token(nil, _source_ip), do: {:error, :token_required}
  defp validate_bootstrap_token("", _source_ip), do: {:error, :token_required}

  defp validate_bootstrap_token(token, source_ip) do
    case NatsPlatformToken.find_and_use(token, source_ip) do
      {:ok, _token_record} -> :ok
      {:error, _reason} -> {:error, :token_invalid}
    end
  end

  defp do_bootstrap(operator_name, existing_seed, generate_system) do
    # Check if already initialized
    case get_current_operator() do
      {:ok, _operator} ->
        {:error, :already_initialized}

      {:error, :not_found} ->
        # Call datasvc to bootstrap
        opts =
          [operator_name: operator_name, generate_system_account: generate_system]
          |> maybe_add_seed(existing_seed)

        case AccountClient.bootstrap_operator(opts) do
          {:ok, result} ->
            # Create NatsOperator record
            case create_operator_record(operator_name, result) do
              {:ok, _operator} -> {:ok, result}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp maybe_add_seed(opts, nil), do: opts
  defp maybe_add_seed(opts, ""), do: opts
  defp maybe_add_seed(opts, seed), do: Keyword.put(opts, :existing_operator_seed, seed)

  defp create_operator_record(name, result) do
    NatsOperator
    |> Ash.Changeset.for_create(:bootstrap, %{
      name: name,
      public_key: result.operator_public_key,
      operator_jwt: result.operator_jwt,
      system_account_public_key: result.system_account_public_key
    })
    |> Ash.create(authorize?: false)
  end

  defp get_current_operator do
    case NatsOperator
         |> Ash.Query.for_read(:get_current)
         |> Ash.Query.limit(1)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, operator} -> {:ok, operator}
      {:error, error} -> {:error, error}
    end
  end

  defp get_tenant(tenant_id) do
    case ServiceRadar.Identity.Tenant
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, tenant} -> {:ok, tenant}
      {:error, error} -> {:error, error}
    end
  end

  defp tenant_to_json(tenant) do
    %{
      id: tenant.id,
      slug: tenant.slug,
      name: tenant.name,
      nats_account_status: to_string(tenant.nats_account_status),
      nats_account_public_key: tenant.nats_account_public_key
    }
  end

  defp get_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end
end
