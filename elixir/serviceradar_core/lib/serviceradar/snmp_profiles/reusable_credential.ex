defmodule ServiceRadar.SNMPProfiles.ReusableCredential do
  @moduledoc """
  Creates a reusable SNMP credential from SNMP credential field values.

  The values are routed through `CredentialSecretBuilder` against the native
  SNMP descriptor rather than being assembled by the caller, so a shared SNMP
  credential is validated, encoded, fingerprinted and redacted by exactly the
  same code as a package-owned one. Choosing the auth method from the SNMP
  version is the only SNMP-specific decision. A community credential stores
  its version (`v1` or `v2c`) with the community, so a job or profile that
  references it without a version of its own still delivers that version.

  Used by the SNMP profile form's "save as reusable" and by the mapper job
  credential backfill, which promotes inline profile material the same way.
  """

  alias ServiceRadar.Credentials.CredentialSecretBuilder
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter

  @fields ~w(community username security_level auth_protocol auth_password priv_protocol priv_password)

  @doc """
  Creates the credential. `field_values` maps the SNMP field names
  (`community`, `username`, `security_level`, `auth_protocol`, `auth_password`,
  `priv_protocol`, `priv_password`) to values; blank values are dropped. `opts` takes
  `:description` and the Ash authorization options (`:scope` or `:actor`).
  """
  @spec create(atom() | String.t(), String.t(), map(), keyword()) ::
          {:ok, NetworkCredentialSecret.t()} | {:error, term()}
  def create(version, name, field_values, opts) do
    version = to_string(version)
    auth_method = if version in ["v1", "v2c"], do: "community", else: "v3"
    {description, ash_opts} = Keyword.pop(opts, :description)

    values =
      field_values
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(@fields)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or String.trim(to_string(value)) == "" end)
      |> Map.new(fn {key, value} -> {key, stored_name(key, to_string(value))} end)
      |> put_community_version(auth_method, version)

    with {:ok, descriptor} <- fetch_descriptor(),
         {:ok, attrs} <-
           CredentialSecretBuilder.build(descriptor, auth_method, values, %{
             name: name,
             description: description
           }) do
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, attrs, ash_opts)
      |> Ash.create(ash_opts)
    end
  end

  defp put_community_version(values, "community", version),
    do: Map.put(values, "version", version)

  defp put_community_version(values, _auth_method, _version), do: values

  defp fetch_descriptor do
    case NativeDescriptors.fetch("snmp") do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> {:error, :snmp_descriptor_unavailable}
    end
  end

  # A profile holds its protocols as attribute names (`sha256`); a credential
  # stores the spelling the credential form offers (`SHA256`). A name the
  # formatter does not know is passed through for the builder to reject, rather
  # than dropped here.
  #
  # A level is stored only when the caller passes one. The SNMP profile form does
  # not: a profile left on its no-auth default still has its level inferred from
  # the passwords (see `CredentialResolver`), and writing that default into the
  # credential would make it explicit and discard the passwords.
  defp stored_name("security_level", value),
    do: ProtocolFormatter.security_level_value(value) || value

  defp stored_name("auth_protocol", value),
    do: ProtocolFormatter.auth_protocol_value(value) || value

  defp stored_name("priv_protocol", value),
    do: ProtocolFormatter.priv_protocol_value(value) || value

  defp stored_name(_field, value), do: value
end
