defmodule ServiceRadar.NetworkDiscovery.Validations.SNMPCredential do
  @moduledoc """
  Ensures a mapper job's SNMP credential reference names a reusable SNMP
  credential.

  A credential is SNMP when it was created as one (`credential_kind: :snmp`) or
  belongs to the SNMP provider, which is how credentials bound through SNMP
  credential rules were stored before the SNMP kind existed. Any other credential
  would compile into mapper config the mapper cannot use.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret

  require Logger

  # The referenced credential is checked here, in Elixir, before the atomic
  # update runs; the foreign key guards the reference afterwards.
  @impl true
  def atomic(changeset, _opts, _context) do
    case Keyword.fetch(changeset.atomics, :snmp_credential_secret_id) do
      {:ok, secret_id} when is_binary(secret_id) -> validate_secret(secret_id)
      _other -> validate_change(changeset)
    end
  end

  @impl true
  def validate(changeset, _opts, _context), do: validate_change(changeset)

  defp validate_change(changeset) do
    case Ash.Changeset.fetch_change(changeset, :snmp_credential_secret_id) do
      {:ok, secret_id} when is_binary(secret_id) -> validate_secret(secret_id)
      _unchanged_or_cleared -> :ok
    end
  end

  @doc "Whether a credential can serve as an SNMP credential."
  @spec snmp_credential?(map()) :: boolean()
  def snmp_credential?(%{credential_kind: :snmp}), do: true
  def snmp_credential?(%{provider: "snmp"}), do: true
  def snmp_credential?(_secret), do: false

  defp validate_secret(secret_id) do
    actor = SystemActor.system(:mapper_job_snmp_credential_validation)

    case NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
      {:ok, nil} ->
        {:error, field: :snmp_credential_secret_id, message: "credential not found"}

      {:ok, secret} ->
        if snmp_credential?(secret),
          do: :ok,
          else: {:error, field: :snmp_credential_secret_id, message: "is not an SNMP credential"}

      {:error, %Ash.Error.Invalid{}} ->
        {:error, field: :snmp_credential_secret_id, message: "credential not found"}

      {:error, reason} ->
        Logger.error("SNMP credential lookup failed during validation: #{inspect(reason)}")
        {:error, field: :snmp_credential_secret_id, message: "credential lookup failed"}
    end
  end
end
