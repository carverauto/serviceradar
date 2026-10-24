defmodule ServiceRadar.Camera.ArchiveQualifications do
  @moduledoc """
  Receives bounded qualification claims from a trusted internal system actor.

  The transport must authenticate its caller before constructing that actor.
  Revisions order received submissions and withdrawals only. Receipt timestamps
  never establish evidence freshness, and every binding remains unqualified.
  """
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveQualificationReceipt
  alias ServiceRadar.Camera.ArchiveQualificationReport
  alias ServiceRadar.Repo

  require Ash.Query

  @fields ~w(report revision schema_version state)
  @max_revision 9_223_372_036_854_775_807

  def submit(binding_id, document, opts \\ []) do
    with :ok <- submitter(opts),
         :ok <- binding_id(binding_id),
         :ok <- outside_transaction(),
         {:ok, input} <- submission(document) do
      transaction(fn ->
        with {:ok, binding} <- binding(binding_id, opts, true),
             :ok <- matching_binding(input, binding),
             {:ok, current} <- receipt(binding_id, opts) do
          receive_submission(current, binding_id, input, opts)
        end
      end)
    end
  end

  def status(binding_id, opts \\ []) do
    with :ok <- submitter(opts),
         :ok <- binding_id(binding_id),
         {:ok, _binding} <- binding(binding_id, opts, false) do
      receipt(binding_id, opts)
    end
  end

  defp submission(%{"schema_version" => 1, "revision" => revision} = document)
       when map_size(document) == 4 and is_integer(revision) and revision in 1..@max_revision do
    with true <- Enum.sort(Map.keys(document)) == @fields,
         {:ok, report} <- report(document["state"], document["report"]) do
      {:ok, Map.put(report, :revision, revision)}
    else
      _ -> {:error, :invalid_qualification_submission}
    end
  end

  defp submission(_), do: {:error, :invalid_qualification_submission}

  defp report("withdrawn", nil), do: {:ok, %{state: :withdrawn, report: nil, report_sha256: nil}}

  defp report("submitted", document) do
    case ArchiveQualificationReport.parse(document) do
      {:ok, parsed} ->
        {:ok,
         %{
           state: :submitted,
           report: parsed.document,
           report_sha256: parsed.report_sha256,
           destination_sha256: parsed.destination_sha256
         }}

      {:error, _} ->
        {:error, :invalid_qualification_submission}
    end
  end

  defp report(_, _), do: {:error, :invalid_qualification_submission}

  defp matching_binding(%{state: :withdrawn}, _binding), do: :ok

  defp matching_binding(input, binding) do
    if input.report["binding_id"] == binding.id and
         input.destination_sha256 == binding.destination_sha256,
       do: :ok,
       else: {:error, :qualification_binding_mismatch}
  end

  defp receive_submission(current, binding_id, input, opts) do
    sha = receipt_digest(binding_id, input)

    cond do
      current && input.revision < current.revision ->
        {:error, :qualification_revision_stale}

      current && input.revision == current.revision && sha != current.receipt_sha256 ->
        {:error, :qualification_revision_conflict}

      current && input.revision == current.revision ->
        {:ok, current}

      true ->
        attributes =
          input
          |> Map.take([:revision, :state, :report, :report_sha256])
          |> Map.merge(%{receipt_sha256: sha, received_at: DateTime.utc_now()})

        persist(current, binding_id, attributes, opts)
    end
  end

  defp persist(nil, binding_id, attributes, opts) do
    ArchiveQualificationReceipt
    |> Ash.Changeset.for_create(:receive, Map.put(attributes, :archive_binding_id, binding_id))
    |> Ash.create(opts)
  end

  defp persist(current, _binding_id, attributes, opts) do
    current |> Ash.Changeset.for_update(:replace, attributes) |> Ash.update(opts)
  end

  defp receipt_digest(binding_id, input) do
    bytes =
      Jason.encode!([
        "archive-qualification-v1",
        binding_id,
        input.revision,
        input.state,
        input.report_sha256
      ])

    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  defp binding(id, opts, lock?) do
    query = ArchiveBinding |> Ash.Query.for_read(:read, %{}, opts) |> Ash.Query.filter(id == ^id)
    query = if lock?, do: Ash.Query.lock(query, :for_update), else: query

    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:error, :archive_binding_not_found}
      result -> bounded_result(result)
    end
  end

  defp receipt(binding_id, opts) do
    ArchiveQualificationReceipt
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(archive_binding_id == ^binding_id)
    |> Ash.read_one(opts)
    |> bounded_result()
  end

  defp binding_id(id) when is_binary(id) do
    if match?({:ok, ^id}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, :invalid_archive_binding_id}
  end

  defp binding_id(_), do: {:error, :invalid_archive_binding_id}

  defp submitter(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system, id: id} when is_binary(id) and byte_size(id) in 1..128 ->
        if String.valid?(id) and String.trim(id) == id and
             not String.contains?(id, [<<0>>, "\r", "\n"]),
           do: :ok,
           else: {:error, :invalid_qualification_submitter}

      _ ->
        {:error, :invalid_qualification_submitter}
    end
  end

  defp outside_transaction do
    if Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok
  end

  defp transaction(fun) do
    [ArchiveBinding, ArchiveQualificationReceipt]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :archive_qualification,
             value: reason,
             message: "qualification submission refused"
           )}

        result ->
          result
      end
    end)
    |> case do
      {:ok, result} ->
        bounded_result(result)

      {:error, %InvalidArgument{field: :archive_qualification, value: reason}} ->
        {:error, reason}

      {:error,
       %Ash.Error.Invalid{
         errors: [%InvalidArgument{field: :archive_qualification, value: reason}]
       }} ->
        {:error, reason}

      _ ->
        {:error, :qualification_storage_unavailable}
    end
  end

  defp bounded_result({:ok, _} = result), do: result
  defp bounded_result({:error, _}), do: {:error, :qualification_storage_unavailable}
end
