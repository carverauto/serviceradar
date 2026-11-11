defmodule ServiceRadar.Camera.Changes.DecideLocalStorageQualification do
  @moduledoc false
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias ServiceRadar.Camera.ArchiveCanonicalJSON
  alias ServiceRadar.Camera.LocalStorageEvidence
  alias ServiceRadar.Camera.LocalStorageQualificationReport

  @impl true
  def change(changeset, _opts, context) do
    actor = context.actor || %{}

    changeset
    |> Ash.Changeset.force_change_attributes(%{
      storage_id: Map.get(actor, :nvr_storage_id),
      decided_by: Map.get(actor, :id),
      decided_at: DateTime.utc_now(),
      revision: Ash.Changeset.get_argument(changeset, :revision)
    })
    |> Ash.Changeset.before_action(&prepare(&1, actor))
  end

  defp prepare(changeset, actor) do
    case decision(changeset, actor) do
      {:ok, attributes, evidence} ->
        decision = Map.merge(attributes, Map.take(changeset.attributes, [:storage_id, :revision]))

        digest =
          :crypto.hash(
            :sha256,
            ArchiveCanonicalJSON.encode(["nvr-local-storage-decision-v1", decision])
          )

        attributes = Map.put(attributes, :decision_sha256, Base.encode16(digest, case: :lower))

        changeset
        |> Ash.Changeset.force_change_attributes(attributes)
        |> Ash.Changeset.after_action(fn _changeset, retained ->
          cond do
            retained.revision != decision.revision or
                retained.decision_sha256 != attributes.decision_sha256 ->
              {:error, error(:decision_conflict)}

            Ash.Resource.get_metadata(retained, :upsert_skipped) == true ->
              {:ok, retained}

            true ->
              validate_current(retained, evidence)
          end
        end)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, error(reason))
    end
  end

  defp decision(%{action: %{name: :withdraw}} = changeset, _actor) do
    {:ok,
     %{
       state: :withdrawn,
       qualification_report_id: nil,
       health: nil,
       policy: nil,
       reason: Ash.Changeset.get_argument(changeset, :reason)
     }, nil}
  end

  defp decision(changeset, actor) do
    policy = Map.get(actor, :nvr_storage_policy)
    health = Ash.Changeset.get_argument(changeset, :health)
    report_id = Ash.Changeset.get_argument(changeset, :report_id)

    with {:ok, snapshot} <- LocalStorageEvidence.policy_snapshot(policy),
         {:ok, report} when not is_nil(report) <-
           Ash.get(LocalStorageQualificationReport, report_id, actor: actor),
         :ok <- LocalStorageEvidence.validate_health(health, report) do
      {:ok,
       %{
         state: :active,
         qualification_report_id: report.id,
         health: health,
         policy: snapshot,
         reason: nil
       }, {report, policy, health}}
    else
      {:ok, nil} -> {:error, :report_unavailable}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :report_unavailable}
    end
  end

  defp validate_current(retained, nil), do: {:ok, retained}

  defp validate_current(retained, {report, policy, health}) do
    # after_action runs inside the upsert transaction, after its row lock is acquired.
    case LocalStorageEvidence.evaluate(report, policy, health, System.system_time(:millisecond)) do
      %{evidence_status: :current} -> {:ok, retained}
      %{reason: reason} -> {:error, error(reason)}
    end
  end

  defp error(reason),
    do:
      InvalidArgument.exception(
        field: :revision,
        message: "local storage qualification rejected: #{reason}"
      )
end
