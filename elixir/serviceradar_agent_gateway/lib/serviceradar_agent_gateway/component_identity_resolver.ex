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

  require Logger

  @type component_identity :: %{
          component_id: String.t(),
          partition_id: String.t(),
          component_type: atom() | nil
        }

  @doc """
  Resolves component identity from a DER-encoded client certificate.

  Returns component_id, partition_id, and optionally component_type.
  Does NOT return or use any deployment metadata.
  """
  @spec resolve_from_cert(binary()) :: {:ok, component_identity()} | {:error, atom()}
  def resolve_from_cert(cert_der) when is_binary(cert_der) do
    with {:ok, otp_cert} <- decode_cert(cert_der),
         {:ok, cn} <- extract_cn(otp_cert),
         {:ok, parsed} <- parse_cn(cn) do
      component_type = extract_component_type(otp_cert)

      {:ok,
       %{
         component_id: parsed.component_id,
         partition_id: parsed.partition_id,
         component_type: component_type
       }}
    end
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
    case String.split(cn, ".") do
      [component_id, partition_id, "serviceradar"] ->
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      [component_id, partition_id, "serviceradar" | _rest] ->
        # Handle cases like "serviceradar.local" suffix
        {:ok, %{component_id: component_id, partition_id: partition_id}}

      _ ->
        Logger.warning("Invalid certificate CN format: #{cn}")
        {:error, :invalid_cn_format}
    end
  end

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
        case String.split(path, "/") do
          [component_type | _rest] when component_type != "" ->
            String.to_existing_atom(component_type)

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
