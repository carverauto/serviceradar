defmodule ServiceRadar.Credentials.Validations.TrustMaterial do
  @moduledoc """
  Validates operator-supplied TLS trust material on a network credential rule.

  Trust material lets a rule satisfy a mandatory `verify` transport policy
  against an appliance presenting a privately-issued or self-signed
  certificate - a Proxmox VE node, for example. It is a trust anchor rather
  than an authenticator, so it is stored in the clear alongside the rule and
  never routed through the credential broker.

  A rule carries at most one form: either a PEM chain or a leaf fingerprint.
  Both are checked here rather than at connection time, because a rule that
  only fails hours later inside a plugin run is exactly the failure mode this
  material exists to remove.

  An atomic update validates the form it is about to write in Elixir. Whether
  the other form is already set is only known to the row, since an atomic
  changeset carries no original record, so that half of the exclusivity check
  runs in the database.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias ServiceRadar.Credentials.Validations.ProposedValue

  @fingerprint_format ~r/\Asha256:[0-9a-f]{64}\z/
  @combined_message "cannot be combined with a CA bundle; supply one form of trust material"

  @impl true
  def atomic(changeset, _opts, _context) do
    atomic_material(
      ProposedValue.fetch(changeset, :ca_bundle_pem),
      ProposedValue.fetch(changeset, :server_cert_fingerprint)
    )
  end

  @impl true
  def validate(changeset, _opts, _context) do
    validate_material(
      trimmed(changeset, :ca_bundle_pem),
      trimmed(changeset, :server_cert_fingerprint)
    )
  end

  defp atomic_material({:not_atomic, _reason} = not_atomic, _fingerprint), do: not_atomic
  defp atomic_material(_bundle, {:not_atomic, _reason} = not_atomic), do: not_atomic

  defp atomic_material(bundle, fingerprint) do
    case {supplied(bundle), supplied(fingerprint)} do
      {nil, nil} ->
        :ok

      {bundle, nil} ->
        bundle |> validate_bundle() |> exclusive_with(:server_cert_fingerprint)

      {nil, fingerprint} ->
        fingerprint |> validate_fingerprint() |> exclusive_with(:ca_bundle_pem)

      {bundle, fingerprint} ->
        validate_material(bundle, fingerprint)
    end
  end

  # The supplied form is valid; the row must not already hold the other one.
  # `atomic_ref/1` is the value this update writes when it sets that field, and
  # the stored value when it does not.
  defp exclusive_with(:ok, other_field) do
    message = @combined_message

    {:atomic, [other_field], expr(not is_nil(^atomic_ref(other_field))),
     expr(error(^InvalidAttribute, %{field: :server_cert_fingerprint, message: ^message}))}
  end

  defp exclusive_with(error, _other_field), do: error

  defp validate_material(bundle, fingerprint) do
    cond do
      bundle != nil and fingerprint != nil ->
        {:error, field: :server_cert_fingerprint, message: @combined_message}

      bundle != nil ->
        validate_bundle(bundle)

      fingerprint != nil ->
        validate_fingerprint(fingerprint)

      true ->
        :ok
    end
  end

  defp validate_bundle(bundle) do
    case :public_key.pem_decode(bundle) do
      [] ->
        {:error, field: :ca_bundle_pem, message: "is not a valid PEM certificate chain"}

      entries ->
        if Enum.all?(entries, &match?({:Certificate, _der, :not_encrypted}, &1)) do
          validate_bundle_validity(entries)
        else
          {:error,
           field: :ca_bundle_pem, message: "must contain only unencrypted CERTIFICATE blocks"}
        end
    end
  end

  defp validate_bundle_validity(entries) do
    if Enum.any?(entries, &expired?/1) do
      {:error, field: :ca_bundle_pem, message: "contains an expired certificate"}
    else
      :ok
    end
  rescue
    # A structurally valid PEM block can still fail OTP certificate decoding.
    # Treat that as invalid material rather than letting it raise into the
    # changeset.
    _ -> {:error, field: :ca_bundle_pem, message: "is not a valid PEM certificate chain"}
  end

  defp expired?({:Certificate, der, :not_encrypted}) do
    {:Certificate, tbs, _alg, _sig} = :public_key.der_decode(:Certificate, der)
    {:TBSCertificate, _v, _sn, _sa, _iss, validity, _subj, _spki, _iu, _su, _ext} = tbs
    {:Validity, _not_before, not_after} = validity

    case not_after_to_datetime(not_after) do
      {:ok, expires_at} -> DateTime.before?(expires_at, DateTime.utc_now())
      :error -> false
    end
  end

  defp not_after_to_datetime({:utcTime, time}) do
    # RFC 5280 UTCTime is YYMMDDHHMMSSZ, with years 50-99 meaning 19xx.
    with <<yy::binary-2, rest::binary>> <- to_string(time),
         {year, ""} <- Integer.parse(yy) do
      century = if year >= 50, do: 1900, else: 2000
      parse_generalized("#{century + year}#{rest}")
    else
      _ -> :error
    end
  end

  defp not_after_to_datetime({:generalTime, time}), do: parse_generalized(to_string(time))
  defp not_after_to_datetime(_), do: :error

  defp parse_generalized(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2,
           _rest::binary>>
       ) do
    with {:ok, date} <- Date.from_iso8601("#{y}-#{mo}-#{d}"),
         {:ok, time} <- Time.from_iso8601("#{h}:#{mi}:#{s}") do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> :error
    end
  end

  defp parse_generalized(_), do: :error

  defp validate_fingerprint(fingerprint) do
    if Regex.match?(@fingerprint_format, fingerprint) do
      :ok
    else
      {:error,
       field: :server_cert_fingerprint,
       message: "must be sha256: followed by 64 lowercase hex characters"}
    end
  end

  defp supplied({:changed, value}), do: blank_to_nil(value)
  defp supplied(:unchanged), do: nil

  defp trimmed(changeset, field) do
    changeset
    |> Ash.Changeset.get_attribute(field)
    |> blank_to_nil()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
