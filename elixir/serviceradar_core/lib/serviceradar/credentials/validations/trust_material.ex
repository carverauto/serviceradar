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
  """

  use Ash.Resource.Validation

  @fingerprint_format ~r/\Asha256:[0-9a-f]{64}\z/

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    bundle = trimmed(changeset, :ca_bundle_pem)
    fingerprint = trimmed(changeset, :server_cert_fingerprint)

    cond do
      bundle != nil and fingerprint != nil ->
        {:error,
         field: :server_cert_fingerprint,
         message: "cannot be combined with a CA bundle; supply one form of trust material"}

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

  defp trimmed(changeset, field) do
    case Ash.Changeset.get_attribute(changeset, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
