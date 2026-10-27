defmodule ServiceRadar.Camera.ArchiveAuthorityConfig do
  @moduledoc """
  Complete bounded identity for a nonrenewable operation-specific installation.

  Parsing grants no authority. The authenticated challenge/application owner
  checks required observations, freshness and the installed principal separately.
  This pure format is shared by core and the isolated credential-holding service.
  """

  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.ArchiveQualificationReport

  @fields ~w(schema_version revision binding_id local_storage_id qualification_report operation protection_mode limits)
  @maximum 9_223_372_036_854_775_807

  def parse(
        kind,
        %{deployment_ref: ref, generation: generation},
        %{"schema_version" => 1, "operation" => operation, "protection_mode" => "sse_s3_aes256"} =
          document
      )
      when kind in [:init, :media, :manifest] and is_integer(generation) and
             generation in 1..@maximum do
    with true <- exact_keys?(document, @fields) and operation == operation(kind),
         true <-
           uuid?(ref) and uuid?(document["binding_id"]) and uuid?(document["local_storage_id"]),
         {:ok, revision} <- revision(document["revision"]),
         true <- limits?(kind, document["limits"]),
         {:ok, report} <- ArchiveQualificationReport.parse(document["qualification_report"]),
         true <- report.document["binding_id"] == document["binding_id"] do
      bytes =
        ArchiveCanonicalJSON.encode([
          domain(kind),
          ref,
          Integer.to_string(generation),
          document
        ])

      {:ok,
       %{
         document: document,
         desired_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
         revision: revision,
         binding_id: document["binding_id"],
         local_storage_id: document["local_storage_id"],
         report: report.document,
         report_sha256: report.report_sha256,
         destination_sha256: report.destination_sha256,
         limits: document["limits"]
       }}
    else
      _ -> invalid(kind)
    end
  end

  def parse(kind, _, _), do: invalid(kind)

  defp revision(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {number, ""} when number in 1..@maximum ->
        if Integer.to_string(number) == value, do: {:ok, number}, else: :error

      _ ->
        :error
    end
  end

  defp revision(_), do: :error

  def kind(%{"operation" => "init_put_verified_v1"}), do: {:ok, :init}
  def kind(%{"operation" => "media_put_verified_v1"}), do: {:ok, :media}
  def kind(%{"operation" => "manifest_put_verified_v1"}), do: {:ok, :manifest}
  def kind(_), do: {:error, :invalid_archive_operation}

  def byte_limit(:init, limits), do: limits["max_init_bytes"]
  def byte_limit(:media, limits), do: limits["max_media_bytes"]
  def byte_limit(:manifest, limits), do: limits["max_manifest_bytes"]

  defp operation(:init), do: "init_put_verified_v1"
  defp operation(:media), do: "media_put_verified_v1"
  defp operation(:manifest), do: "manifest_put_verified_v1"
  defp domain(:init), do: "init-authority-v1"
  defp domain(:media), do: "media-authority-v1"
  defp domain(:manifest), do: "manifest-authority-v1"
  defp invalid(:init), do: {:error, :invalid_init_configuration}
  defp invalid(:manifest), do: {:error, :invalid_manifest_configuration}
  defp invalid(_), do: {:error, :invalid_media_configuration}

  defp limits?(kind, %{"max_operation_ms" => ms, "max_in_flight" => 1} = limits)
       when map_size(limits) == 3 do
    bytes = byte_limit(kind, limits)
    {max_bytes, max_ms} = bounds(kind)
    is_integer(bytes) and bytes in 1..max_bytes and is_integer(ms) and ms in 1..max_ms
  end

  defp limits?(_, _), do: false

  defp bounds(:init), do: {1_048_576, 5000}
  defp bounds(:media), do: {16_777_216, 30_000}
  defp bounds(:manifest), do: {2_097_152, 30_000}

  defp uuid?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_), do: false

  defp exact_keys?(value, keys), do: Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
