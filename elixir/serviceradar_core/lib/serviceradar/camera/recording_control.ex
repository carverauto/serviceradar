defmodule ServiceRadar.Camera.RecordingControl do
  @moduledoc """
  Durable stop-only restriction on the existing local recording path.

  The authenticated transport supplies the installed origin and an explicit
  system actor. No accepted document enables or resumes recording. Stop success
  proves the durable gates deny new work, never that all replicas have drained.

  Lock order is control singleton, then init authority when granting, then
  ingest owner when recording, then recorder claim or block, then dispatch.
  Acquire, renew, reserve, dispatch mark, and init or manifest dispatch
  preparation take this outer fence. Media dispatch preparation, publication,
  freeze, release and late observations remain usable.
  No media, provider I/O or worker enumeration occurs under the control lock.
  New-work callers acquire this fence before entering any preservation callback.
  Stop rejects ambient transactions so success means its restriction committed.
  """
  alias Ash.Error.Query.InvalidArgument
  alias ServiceRadar.Camera.RecordingControlState
  alias ServiceRadar.Repo

  require Ash.Query

  @maximum 9_223_372_036_854_775_807

  def stop(installation, document, opts \\ []) do
    with :ok <- submitter(opts),
         :ok <- installation(installation),
         {:ok, revision} <- document(document),
         :ok <- outside_transaction() do
      fn ->
        with {:ok, current} <- locked(opts),
             :ok <- origin(current, installation),
             {:ok, stopped} <- receive_stop(current, installation, revision, opts) do
          {:ok, projection(stopped)}
        end
      end
      |> transaction()
      |> bounded_response()
    end
  end

  def status(installation, opts \\ []) do
    with :ok <- submitter(opts),
         :ok <- installation(installation) do
      fn ->
        with {:ok, current} <- locked(opts), :ok <- origin(current, installation) do
          {:ok, projection(current)}
        end
      end
      |> transaction()
      |> bounded_response()
    end
  end

  @doc "Runs short new-work admission with the control lock acquired first."
  def with_admission(fun, opts) when is_function(fun, 0) do
    transaction(fn ->
      with {:ok, current} <- locked(opts),
           :ok <- if(current.stopped, do: {:error, :recording_stopped}, else: :ok) do
        fun.()
      end
    end)
  end

  defp locked(opts) do
    with {:ok, _baseline} <-
           RecordingControlState
           |> Ash.Changeset.for_create(:initialize, %{})
           |> Ash.create(opts) do
      RecordingControlState
      |> Ash.Query.filter(id == "deployment")
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(opts)
    end
  end

  defp receive_stop(current, installation, revision, opts) do
    digest = desired_digest(installation, revision)

    cond do
      current.stopped and revision < current.revision ->
        {:error, :recording_revision_stale}

      current.stopped and revision == current.revision and digest != current.desired_digest ->
        {:error, :recording_revision_conflict}

      current.stopped and revision == current.revision ->
        {:ok, current}

      true ->
        current
        |> Ash.Changeset.for_update(:stop, %{
          deployment_ref: installation.deployment_ref,
          generation: installation.generation,
          revision: revision,
          desired_digest: digest,
          received_at: DateTime.utc_now()
        })
        |> Ash.update(opts)
    end
  end

  defp origin(%{stopped: false}, _installation), do: :ok

  defp origin(current, installation) do
    cond do
      current.deployment_ref != installation.deployment_ref ->
        {:error, :recording_installation_mismatch}

      installation.generation < current.generation ->
        {:error, :recording_generation_stale}

      true ->
        :ok
    end
  end

  defp projection(current) do
    %{
      "contract_version" => 1,
      "stop_enforced" => current.stopped,
      "desired_revision" => if(current.revision, do: Integer.to_string(current.revision)),
      "desired_digest" => current.desired_digest,
      "received_at" => if(current.received_at, do: DateTime.to_iso8601(current.received_at)),
      "applied_revision" => nil,
      "readiness" => "unavailable",
      "reason" => "recording_stop_only",
      "drain_status" => "not_attested"
    }
  end

  defp desired_digest(installation, revision) do
    bytes =
      Jason.encode!([
        "recording-stop-v1",
        installation.deployment_ref,
        Integer.to_string(installation.generation),
        1,
        Integer.to_string(revision),
        "stopped"
      ])

    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  defp document(
         %{"contract_version" => 1, "revision" => revision, "admission" => "stopped"} = document
       )
       when map_size(document) == 3 and is_binary(revision) and byte_size(revision) in 1..19 do
    case Integer.parse(revision) do
      {number, ""} when number in 1..@maximum ->
        if Integer.to_string(number) == revision,
          do: {:ok, number},
          else: {:error, :invalid_recording_configuration}

      _ ->
        {:error, :invalid_recording_configuration}
    end
  end

  defp document(_), do: {:error, :invalid_recording_configuration}

  defp installation(%{deployment_ref: id, generation: generation})
       when is_binary(id) and is_integer(generation) and generation in 1..@maximum do
    if match?({:ok, ^id}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, :invalid_recording_installation}
  end

  defp installation(_), do: {:error, :invalid_recording_installation}

  defp submitter(opts) do
    case Keyword.get(opts, :actor) do
      %{role: :system, id: id} when is_binary(id) and byte_size(id) in 1..128 ->
        if String.valid?(id) and String.trim(id) == id and
             not String.contains?(id, [<<0>>, "\r", "\n"]),
           do: :ok,
           else: {:error, :invalid_recording_submitter}

      _ ->
        {:error, :invalid_recording_submitter}
    end
  end

  defp outside_transaction do
    if Repo.in_transaction?(), do: {:error, :ambient_transaction}, else: :ok
  end

  defp transaction(fun) do
    [RecordingControlState]
    |> Ash.transact(fn ->
      case fun.() do
        {:error, reason} when is_atom(reason) ->
          {:error,
           InvalidArgument.exception(
             field: :recording_control,
             value: reason,
             message: "recording operation refused"
           )}

        result ->
          result
      end
    end)
    |> transaction_result()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :recording_control_unavailable}
  end

  defp transaction_result({:ok, result}), do: result

  defp transaction_result({:error, %Ash.Error.Invalid{errors: [error]}}),
    do: transaction_result({:error, error})

  # Nested Ash transactions share the connection. An inner rollback reaches
  # this outer boundary before the ingest/block owner can unwrap its refusal.
  defp transaction_result({:error, %{__struct__: type, field: field, value: reason}})
       when type in [InvalidArgument, Ash.Error.Changes.InvalidArgument] and
              field in [:recording_control, :ingest_ownership, :recording_block, :init_authority],
       do: {:error, reason}

  defp transaction_result(error), do: error
  defp bounded_response({:ok, _} = result), do: result
  defp bounded_response({:error, reason} = result) when is_atom(reason), do: result
  defp bounded_response(_), do: {:error, :recording_control_unavailable}
end
