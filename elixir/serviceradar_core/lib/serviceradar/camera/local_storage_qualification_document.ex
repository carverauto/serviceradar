defmodule ServiceRadar.Camera.LocalStorageQualificationDocument do
  @moduledoc """
  Bounded, canonical evidence report for one local-storage binding generation.

  Parsing and hashing do not authenticate the issuer, verify evidence, evaluate
  freshness or activate qualification, even when every check passed. Historical
  reports may contain expired observations or unsuccessful checks. A transport
  must bound input before decoding and reject duplicate JSON keys.
  """

  alias ServiceRadar.Camera.ArchiveCanonicalJSON

  @fields ~w(schema_version binding_id storage_id binding_sha256 profile_sha256 revision evidence_sha256 policy_revision issued_at_ms expires_at_ms checks)
  @checks ~w(acknowledged_writes_survive_worker_disk_loss replica_placement_and_health provider_attachment_fencing application_writer_ownership reattachment_preserves_identity_and_bytes retained_volume_lifecycle restore_preserves_history)
  @statuses ~w(passed failed not_tested not_confirmed unsupported)
  @max_integer 9_223_372_036_854_775_807

  def attributes(%{"schema_version" => 1} = document) when map_size(document) == 11 do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         true <- uuid?(document["binding_id"]),
         true <- uuid?(document["storage_id"]),
         true <- digest?(document["binding_sha256"]),
         true <- digest?(document["profile_sha256"]),
         true <- digest?(document["evidence_sha256"]),
         true <- positive_integer?(document["revision"]),
         true <- token?(document["policy_revision"]),
         true <- positive_integer?(document["issued_at_ms"]),
         true <- positive_integer?(document["expires_at_ms"]),
         true <- document["issued_at_ms"] < document["expires_at_ms"],
         true <- checks?(document["checks"]) do
      bytes = ArchiveCanonicalJSON.encode(["nvr-local-storage-qualification-report-v1", document])

      {:ok,
       %{
         local_storage_binding_id: document["binding_id"],
         revision: document["revision"],
         report: document,
         report_sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
       }}
    else
      _ -> {:error, :invalid_local_storage_qualification_report}
    end
  end

  def attributes(_), do: {:error, :invalid_local_storage_qualification_report}

  defp uuid?(id) when is_binary(id) and byte_size(id) == 36, do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false
  defp positive_integer?(value), do: is_integer(value) and value in 1..@max_integer

  defp token?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)

  defp token?(_), do: false

  defp checks?(checks) when is_map(checks) and map_size(checks) == 7,
    do:
      Enum.sort(Map.keys(checks)) == Enum.sort(@checks) and
        Enum.all?(Map.values(checks), &(&1 in @statuses))

  defp checks?(_), do: false
end
