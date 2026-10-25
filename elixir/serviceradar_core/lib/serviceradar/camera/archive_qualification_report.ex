defmodule ServiceRadar.Camera.ArchiveQualificationReport do
  @moduledoc """
  Bounded version 1 observations for a mediated recording archive.

  Parsing establishes format and content identity only. It does not authenticate
  the reporter, verify its observations, resolve credentials, establish freshness
  or grant storage authority. Even a report containing only `passed` observations
  cannot qualify a destination or enable dispatch. The authenticated configuration
  and storage boundaries must enforce those separate contracts.
  """

  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.ArchiveDestination

  @fields ~w(schema_version binding_id destination provider_resource_id endpoint_type credential policy_revision operation_mode issued_at_ms expires_at_ms result_ref checks)
  @credential_fields ~w(reference generation storage_service_id)
  @checks ~w(intended_operations anonymous_access_denied foreign_environment_access_denied recorder_privilege_boundary reader_privilege_boundary private_acl_policy endpoint_tls_redirect_boundary browser_cors put_aes256_attestation multipart_aes256_attestation put_missing_aes256_denied put_noncompliant_aes256_denied multipart_missing_aes256_denied multipart_noncompliant_aes256_denied atomic_put_no_overwrite atomic_completion_no_overwrite integrity_object_identity conditional_ranges multipart_recovery)
  @statuses ~w(passed failed not_tested not_confirmed unsupported)
  @max_integer 9_223_372_036_854_775_807

  @doc """
  Parses a decoded JSON object and returns its canonical bytes and SHA-256.

  Canonical JSON recursively orders object keys by ASCII byte order, uses compact
  JSON encoding and retains all values. Inputs use string keys; unknown/missing
  fields and unsupported versions are rejected. The surrounding transport must
  bound its input before decoding and reject duplicate JSON object keys.
  """
  def parse(%{"schema_version" => 1, "operation_mode" => "mediated_immutable_archive_v1"} = input) do
    with true <- exact_keys?(input, @fields),
         true <- uuid?(input["binding_id"]),
         {:ok, destination} <- ArchiveDestination.attributes(input["destination"]),
         true <- reference?(input["provider_resource_id"]),
         true <- token?(input["endpoint_type"]),
         true <- credential?(input["credential"]),
         true <- token?(input["policy_revision"]),
         true <- token?(input["result_ref"]),
         true <- interval?(input["issued_at_ms"], input["expires_at_ms"]),
         true <- checks?(input["checks"]) do
      bytes = ArchiveCanonicalJSON.encode(input)
      digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      {:ok,
       %{
         document: input,
         canonical_json: bytes,
         report_sha256: digest,
         destination_sha256: destination.destination_sha256
       }}
    else
      _ -> {:error, :invalid_archive_qualification_report}
    end
  end

  def parse(_), do: {:error, :invalid_archive_qualification_report}

  defp credential?(credential) do
    exact_keys?(credential, @credential_fields) and
      reference?(credential["reference"]) and positive_integer?(credential["generation"]) and
      reference?(credential["storage_service_id"])
  end

  defp checks?(checks) do
    exact_keys?(checks, @checks) and Enum.all?(checks, fn {_, status} -> status in @statuses end)
  end

  defp interval?(issued, expires),
    do: positive_integer?(issued) and positive_integer?(expires) and issued < expires

  defp positive_integer?(value), do: is_integer(value) and value in 1..@max_integer

  defp exact_keys?(value, keys) when is_map(value) and map_size(value) == length(keys),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false

  defp uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_), do: false

  defp token?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)

  defp token?(_), do: false

  defp reference?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: Regex.match?(~r/\A[!-~]+\z/, value)

  defp reference?(_), do: false
end
