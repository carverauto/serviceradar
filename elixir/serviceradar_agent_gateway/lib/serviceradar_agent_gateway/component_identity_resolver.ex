defmodule ServiceRadarAgentGateway.ComponentIdentityResolver do
  @moduledoc """
  Extracts component identity from mTLS client certificates.

  Each deployment has its own agent-gateway instance. This module extracts
  component identity (component_id, partition_id, component_type) from certificates
  without any additional deployment metadata.

  ## Certificate CN Format

  Edge component certificates use the format:
  `<component_id>.<partition_id>.serviceradar`

  We extract `component_id` and `partition_id` from the CN.

  ## SPIFFE ID Format

  Component type is extracted from the SPIFFE URI SAN:
  `spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>`
  """

  alias ServiceRadarAgentGateway.AgentCertificateRevocation

  require Logger

  @type component_identity :: %{
          component_id: String.t(),
          partition_id: String.t(),
          component_type: atom() | nil,
          certificate_fingerprint: String.t(),
          cert_fingerprint_sha256: String.t(),
          serial_number: integer(),
          cert_serial: String.t(),
          cert_not_before: DateTime.t(),
          cert_not_after: DateTime.t(),
          cert_expires_at: DateTime.t()
        }

  @doc """
  Resolves component identity from a DER-encoded client certificate.

  Returns component_id, partition_id, component_type, and certificate lifecycle
  metadata (`cert_not_before`, `cert_not_after`, `cert_expires_at`, `cert_serial`,
  `cert_fingerprint_sha256`).
  Does NOT return or use any deployment metadata.
  """
  @spec resolve_from_cert(binary(), keyword()) :: {:ok, component_identity()} | {:error, atom()}
  def resolve_from_cert(cert_der, opts \\ [])

  def resolve_from_cert(cert_der, opts) when is_binary(cert_der) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, otp_cert} <- decode_cert(cert_der),
         {:ok, not_before, not_after} <- extract_validity(otp_cert),
         :ok <- validate_validity_window(not_before, not_after, now),
         {:ok, cn} <- extract_cn(otp_cert),
         {:ok, parsed} <- parse_cn(cn) do
      component_type = extract_component_type(otp_cert)
      fingerprint = certificate_fingerprint(cert_der)
      serial_number = extract_serial_number(otp_cert)
      serial_hex = format_serial_hex(serial_number)

      identity = %{
        component_id: parsed.component_id,
        partition_id: parsed.partition_id,
        component_type: component_type,
        certificate_fingerprint: fingerprint,
        cert_fingerprint_sha256: fingerprint,
        serial_number: serial_number,
        cert_serial: serial_hex,
        cert_not_before: not_before,
        cert_not_after: not_after,
        cert_expires_at: not_after
      }

      reject_revoked(identity)
    end
  end

  @doc """
  Extracts diagnostic metadata from a DER-encoded certificate or `:OTPCertificate`
  tuple without enforcing CN format or validity window. Used for structured TLS
  handshake failure diagnostics.
  """
  @spec extract_cert_metadata(binary() | tuple() | nil) :: map()
  def extract_cert_metadata(cert_der) when is_binary(cert_der) do
    case decode_cert(cert_der) do
      {:ok, otp_cert} ->
        otp_cert
        |> extract_otp_cert_metadata()
        |> Map.put(:fingerprint_sha256, certificate_fingerprint(cert_der))

      {:error, _} ->
        %{fingerprint_sha256: certificate_fingerprint(cert_der)}
    end
  end

  def extract_cert_metadata({:OTPCertificate, _, _, _} = otp_cert) do
    extract_otp_cert_metadata(otp_cert)
  end

  def extract_cert_metadata(_other), do: %{}

  @doc false
  @spec extract_otp_cert_metadata(tuple()) :: map()
  def extract_otp_cert_metadata({:OTPCertificate, tbs_cert, _, _} = otp_cert) do
    subject_cn =
      case extract_cn(otp_cert) do
        {:ok, cn} -> cn
        _ -> format_rdn_sequence(elem(tbs_cert, 6))
      end

    issuer_cn = format_rdn_sequence(elem(tbs_cert, 4))
    serial_number = extract_serial_number(otp_cert)
    serial_hex = format_serial_hex(serial_number)

    {not_before, not_after} =
      case extract_validity(otp_cert) do
        {:ok, nb, na} -> {nb, na}
        _ -> {nil, nil}
      end

    {component_id, partition_id} =
      case subject_cn && parse_cn_quiet(subject_cn) do
        {:ok, %{component_id: cid, partition_id: pid}} -> {cid, pid}
        _ -> {nil, nil}
      end

    %{
      subject: subject_cn,
      issuer: issuer_cn,
      component_id: component_id,
      partition_id: partition_id,
      serial: serial_hex,
      serial_number: serial_number,
      not_before: not_before,
      not_after: not_after
    }
  end

  # Decode DER certificate to OTP certificate record
  defp decode_cert(cert_der) do
    case :public_key.pkix_decode_cert(cert_der, :otp) do
      {:OTPCertificate, _, _, _} = cert -> {:ok, cert}
      _ -> {:error, :invalid_certificate}
    end
  end

  # Extract CN from certificate subject
  defp extract_cn({:OTPCertificate, tbs_cert, _, _}) do
    subject = elem(tbs_cert, 6)

    case subject do
      {:rdnSequence, rdns} ->
        cn =
          rdns
          |> List.flatten()
          |> Enum.find_value(fn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}} -> cn
            {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} -> List.to_string(cn)
            _ -> nil
          end)

        if cn, do: {:ok, cn}, else: {:error, :no_cn}

      _ ->
        {:error, :invalid_subject}
    end
  end

  # Parse CN format: <component_id>.<partition_id>.serviceradar
  defp parse_cn(cn) do
    case parse_cn_quiet(cn) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        Logger.warning("Invalid certificate CN format: #{cn}")
        {:error, reason}
    end
  end

  defp parse_cn_quiet(cn) when is_binary(cn) do
    case String.split(cn, ".") do
      [component_id, partition_id, "serviceradar"] ->
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      [component_id, partition_id, "serviceradar" | _rest] ->
        # Handle cases like "serviceradar.local" suffix
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      _ ->
        {:error, :invalid_cn_format}
    end
  end

  defp format_rdn_sequence({:rdnSequence, rdns}) when is_list(rdns) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}} -> cn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} -> List.to_string(cn)
      _ -> nil
    end)
  end

  defp format_rdn_sequence(_), do: nil

  defp extract_validity({:OTPCertificate, tbs_cert, _, _}) do
    case elem(tbs_cert, 5) do
      {:Validity, not_before_asn1, not_after_asn1} ->
        with {:ok, not_before} <- parse_asn1_time(not_before_asn1),
             {:ok, not_after} <- parse_asn1_time(not_after_asn1) do
          {:ok, not_before, not_after}
        else
          _ -> {:error, :invalid_validity}
        end

      _ ->
        {:error, :invalid_validity}
    end
  end

  defp validate_validity_window(%DateTime{} = not_before, %DateTime{} = not_after, %DateTime{} = now) do
    cond do
      DateTime.before?(now, not_before) ->
        {:error, :certificate_not_yet_valid}

      DateTime.compare(now, not_after) != :lt ->
        {:error, :certificate_expired}

      true ->
        :ok
    end
  end

  defp parse_asn1_time({:utcTime, chars}) when is_list(chars) do
    chars |> List.to_string() |> parse_utc_time()
  end

  defp parse_asn1_time({:utcTime, str}) when is_binary(str) do
    parse_utc_time(str)
  end

  defp parse_asn1_time({:generalTime, chars}) when is_list(chars) do
    chars |> List.to_string() |> parse_general_time()
  end

  defp parse_asn1_time({:generalTime, str}) when is_binary(str) do
    parse_general_time(str)
  end

  defp parse_asn1_time(_), do: :error

  defp parse_utc_time(
         <<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), min::binary-size(2),
           ss::binary-size(2), "Z">>
       ) do
    with {yy_int, ""} <- Integer.parse(yy),
         year = if(yy_int >= 50, do: 1900 + yy_int, else: 2000 + yy_int),
         {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(min),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, DateTime.add(dt, 0, :microsecond)}
    else
      _ -> :error
    end
  end

  defp parse_utc_time(_), do: :error

  defp parse_general_time(
         <<yyyy::binary-size(4), mm::binary-size(2), dd::binary-size(2), hh::binary-size(2), min::binary-size(2),
           ss::binary-size(2), "Z">>
       ) do
    with {year, ""} <- Integer.parse(yyyy),
         {month, ""} <- Integer.parse(mm),
         {day, ""} <- Integer.parse(dd),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(min),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, DateTime.add(dt, 0, :microsecond)}
    else
      _ -> :error
    end
  end

  defp parse_general_time(_), do: :error

  defp format_serial_hex(serial) when is_integer(serial) and serial >= 0 do
    hex =
      serial
      |> Integer.to_string(16)
      |> String.downcase()

    if rem(byte_size(hex), 2) == 1 do
      "0" <> hex
    else
      hex
    end
  end

  defp format_serial_hex(serial), do: to_string(serial)

  # Extract component_type from SPIFFE URI in certificate extensions
  # Format: spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>
  defp extract_component_type({:OTPCertificate, tbs_cert, _, _}) do
    extensions =
      case elem(tbs_cert, 10) do
        :asn1_NOVALUE -> []
        nil -> []
        value -> value
      end

    if is_list(extensions) do
      san_extension =
        Enum.find(extensions, fn
          {:Extension, {2, 5, 29, 17}, _, _} -> true
          _ -> false
        end)

      case san_extension do
        {:Extension, _, _, san_values} ->
          extract_component_type_from_san(san_values)

        _ ->
          nil
      end
    else
      Logger.warning("Unexpected certificate extensions value: #{inspect(extensions)}")
      return_nil()
    end
  end

  defp return_nil, do: nil

  defp extract_component_type_from_san(san_values) when is_list(san_values) do
    Enum.find_value(san_values, fn
      {:uniformResourceIdentifier, uri} ->
        parse_spiffe_component_type(to_string(uri))

      _ ->
        nil
    end)
  end

  defp extract_component_type_from_san(_), do: nil

  # Parse SPIFFE URI to extract component type
  # Format: spiffe://serviceradar.local/<component_type>/...
  defp parse_spiffe_component_type(uri) do
    case URI.parse(uri) do
      %URI{scheme: "spiffe", path: "/" <> path} ->
        # String.split/2 always returns at least one element, so First is the leading path
        # segment or "" -- and "" falls through component_type_atom/1's catch-all, which is
        # what the old `when component_type != ""` guard did.
        path
        |> String.split("/")
        |> List.first()
        |> component_type_atom()

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp component_type_atom("agent"), do: :agent
  defp component_type_atom("addon"), do: :addon
  defp component_type_atom(_), do: nil

  defp certificate_fingerprint(cert_der) do
    :sha256
    |> :crypto.hash(cert_der)
    |> Base.encode16(case: :lower)
  end

  defp extract_serial_number({:OTPCertificate, tbs_cert, _, _}) do
    elem(tbs_cert, 2)
  end

  defp reject_revoked(identity) do
    if AgentCertificateRevocation.revoked?(identity) do
      Logger.warning(
        "Revoked agent certificate rejected: component_id=#{identity.component_id} reason=#{inspect(AgentCertificateRevocation.revoked_reason(identity))}"
      )

      {:error, :revoked_certificate}
    else
      {:ok, identity}
    end
  end
end
