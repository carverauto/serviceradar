defmodule ServiceRadar.Automation.Ansible.ProvisioningIdempotency do
  @moduledoc """
  Serializes a scoped create request and its receipt in one database transaction.

  Callers authorize before entry. Both callbacks must use the initiating scope;
  the internal actor below can access receipts only and never creates the target
  resource. Callbacks perform database work or enqueue durable work, never an
  external mutation while holding the transaction.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.ProvisioningRequest
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON
  alias ServiceRadar.Repo
  alias ServiceRadar.Vault

  require Ash.Query

  @actor SystemActor.system(:ansible_provisioning_receipts)

  @spec run(map(), map(), (-> term()), (String.t() -> term())) :: term()
  def run(identity, params, create, read) do
    case CanonicalJSON.encode(params) do
      {:ok, body} ->
        request_id = identity |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

        case Repo.transaction(fn -> locked_request(request_id, identity, body, create, read) end) do
          {:ok, result} -> result
          {:error, {:request_error, result}} -> result
          {:error, _reason} -> {:error, :idempotency_unavailable}
        end

      {:error, _reason} ->
        {:error, :invalid_idempotent_request}
    end
  end

  defp locked_request(request_id, identity, body, create, read) do
    <<lock_id::signed-64, _::binary>> = :crypto.hash(:sha256, request_id)

    case Repo.query("SELECT pg_try_advisory_xact_lock($1)", [lock_id]) do
      {:ok, %{rows: [[true]]}} ->
        receipt =
          ProvisioningRequest
          |> Ash.Query.for_read(:read, %{}, actor: @actor)
          |> Ash.Query.filter(id == ^request_id)
          |> Ash.read_one(actor: @actor)

        case receipt do
          {:ok, nil} -> create_receipt(request_id, identity, body, create)
          {:ok, receipt} -> replay(receipt, body, read)
          {:error, _reason} -> fail({:error, :idempotency_unavailable})
        end

      {:ok, %{rows: [[false]]}} ->
        fail({:error, :idempotency_in_progress})

      _ ->
        fail({:error, :idempotency_unavailable})
    end
  end

  defp create_receipt(request_id, identity, body, create) do
    key = :crypto.strong_rand_bytes(32)

    with {:ok, encrypted_key} <- Vault.encrypt(key),
         {:ok, resource} <- create.(),
         {:ok, _receipt} <-
           ProvisioningRequest
           |> Ash.Changeset.for_create(
             :create,
             %{
               id: request_id,
               initiator_id: identity.initiator_id,
               operation: identity.operation,
               key_ciphertext: encrypted_key,
               request_mac: :crypto.mac(:hmac, :sha256, key, body),
               resource_id: resource.id
             },
             actor: @actor
           )
           |> Ash.create(actor: @actor) do
      {:ok, resource}
    else
      error -> fail(error)
    end
  end

  defp replay(receipt, body, read) do
    with {:ok, key} <- Vault.decrypt(receipt.key_ciphertext),
         true <-
           Plug.Crypto.secure_compare(receipt.request_mac, :crypto.mac(:hmac, :sha256, key, body)) do
      case read.(receipt.resource_id) do
        {:error, :not_found} -> {:error, :idempotency_resource_deleted}
        result -> result
      end
    else
      false -> {:error, :idempotency_conflict}
      {:error, _reason} -> {:error, :idempotency_unavailable}
    end
  end

  defp fail(result), do: Repo.rollback({:request_error, result})
end
