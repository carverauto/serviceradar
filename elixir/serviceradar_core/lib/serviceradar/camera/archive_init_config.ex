defmodule ServiceRadar.Camera.ArchiveInitConfig do
  @moduledoc """
  Complete bounded identity for a nonrenewable init-object installation.

  Parsing grants no authority. The authenticated challenge/application owner
  checks required observations, freshness and the installed principal separately.
  This pure format is shared by core and the isolated credential-holding service.
  """

  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.ArchiveQualificationReport

  @fields ~w(schema_version revision binding_id local_storage_id qualification_report operation protection_mode limits)
  @maximum 9_223_372_036_854_775_807

  def parse(
        %{deployment_ref: ref, generation: generation},
        %{
          "schema_version" => 1,
          "operation" => "init_put_verified_v1",
          "protection_mode" => "sse_s3_aes256"
        } = document
      )
      when is_integer(generation) and generation in 1..@maximum do
    with true <- exact_keys?(document, @fields),
         true <-
           uuid?(ref) and uuid?(document["binding_id"]) and uuid?(document["local_storage_id"]),
         {:ok, revision} <- revision(document["revision"]),
         true <- limits?(document["limits"]),
         {:ok, report} <- ArchiveQualificationReport.parse(document["qualification_report"]),
         true <- report.document["binding_id"] == document["binding_id"] do
      bytes =
        ArchiveCanonicalJSON.encode([
          "init-authority-v1",
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
      _ -> {:error, :invalid_init_configuration}
    end
  end

  def parse(_, _), do: {:error, :invalid_init_configuration}

  defp revision(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {number, ""} when number in 1..@maximum ->
        if Integer.to_string(number) == value, do: {:ok, number}, else: :error

      _ ->
        :error
    end
  end

  defp revision(_), do: :error

  defp limits?(
         %{"max_init_bytes" => bytes, "max_operation_ms" => ms, "max_in_flight" => 1} = limits
       )
       when map_size(limits) == 3,
       do: is_integer(bytes) and bytes in 1..1_048_576 and is_integer(ms) and ms in 1..5000

  defp limits?(_), do: false

  defp uuid?(value) when is_binary(value),
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_), do: false

  defp exact_keys?(value, keys), do: Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
