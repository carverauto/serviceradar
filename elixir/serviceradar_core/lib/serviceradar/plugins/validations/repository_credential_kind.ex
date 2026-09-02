defmodule ServiceRadar.Plugins.Validations.RepositoryCredentialKind do
  @moduledoc """
  Rejects a `PluginRepository` credential that is not an API token.

  The importer sends the bound secret as a GitHub bearer token. Pointing the FK
  at an SSH key or an SNMP community would not fail at write time -- it would
  fail as a 401 from GitHub, reported as "the release list is empty", which is
  the least useful description of the actual mistake.

  `RepositoryCredentials.put_token/3` always creates `:api_token` secrets, so in
  practice this guards the FK being set by some other path.

  `atomic/3` returns `:ok` because the check needs the referenced row: it runs
  in `validate/3` where a query is available, matching
  `Identity.Validations.RoleMappings` and the other lookup validations here.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :credential_secret_id) do
      # Unset, or not being changed: detaching a credential is always allowed.
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, secret_id} -> validate_kind(secret_id)
    end
  end

  defp validate_kind(secret_id) do
    actor = SystemActor.system(:plugin_repository_credentials)

    case NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
      {:ok, %{credential_kind: :api_token}} ->
        :ok

      {:ok, %{credential_kind: kind}} ->
        invalid("must reference an api_token credential, got #{inspect(kind)}")

      {:error, _reason} ->
        invalid("references a credential that does not exist")
    end
  end

  defp invalid(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :credential_secret_id,
       message: message
     )}
  end
end
