defmodule ServiceRadar.Camera.LocalStorageQualification do
  @moduledoc """
  Current qualification decision for one local-storage lifetime.

  A deployment qualifier supplies an ordered decision revision. PostgreSQL
  serializes conditional upserts on the storage UUID, including across binding
  generations. An exact retry returns the original decision receipt; it never
  renews evidence. Withdrawal can precede activation and needs no fresh evidence.

  `status/1` is an advisory snapshot using Core time and the trusted adapter's
  explicit policy. Registration must lock this row and recheck eligibility in
  its own transaction. Neither a retained receipt nor this snapshot grants
  capture, registration, playback or deletion authority.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  alias ServiceRadar.Camera.Changes.DecideLocalStorageQualification
  alias ServiceRadar.Camera.LocalStorageEvidence
  alias ServiceRadar.Camera.LocalStorageQualificationReport

  postgres do
    table "camera_local_storage_qualifications"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :qualification_report,
        on_delete: :restrict,
        name: "camera_local_storage_qualification_report_fkey"
    end

    check_constraints do
      check_constraint :revision, "camera_local_storage_qualification_revision",
        check: "revision > 0"

      check_constraint :state, "camera_local_storage_qualification_state",
        check: """
        (state = 'active' AND qualification_report_id IS NOT NULL AND
         health IS NOT NULL AND policy IS NOT NULL AND reason IS NULL) OR
        (state = 'withdrawn' AND qualification_report_id IS NULL AND
         health IS NULL AND policy IS NULL AND reason IS NOT NULL)
        """

      check_constraint :decision_sha256, "camera_local_storage_qualification_bounds",
        check: """
        decision_sha256 ~ '^[0-9a-f]{64}$' AND
        (health IS NULL OR (jsonb_typeof(health) = 'object' AND octet_length(health::text) <= 2048)) AND
        (policy IS NULL OR (jsonb_typeof(policy) = 'object' AND octet_length(policy::text) <= 2048))
        """
    end
  end

  code_interface do
    define :activate, args: [:revision, :report_id, :health]
    define :withdraw, args: [:revision, :reason]
    define :status
  end

  actions do
    defaults [:read]

    for action <- [:activate, :withdraw] do
      create action do
        accept []

        argument :revision, :integer,
          allow_nil?: false,
          constraints: [min: 1, max: 9_223_372_036_854_775_807]

        if action == :activate do
          argument :report_id, :uuid, allow_nil?: false
          argument :health, :map, allow_nil?: false, sensitive?: true
        else
          argument :reason, :string,
            allow_nil?: false,
            constraints: [
              min_length: 1,
              max_length: 128,
              match: ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/
            ]
        end

        upsert? true

        upsert_fields [
          :revision,
          :state,
          :qualification_report_id,
          :health,
          :policy,
          :reason,
          :decision_sha256,
          :decided_by,
          :decided_at
        ]

        upsert_condition expr(revision < upsert_conflict(:revision))
        return_skipped_upsert? true
        change DecideLocalStorageQualification
      end
    end

    action :status do
      returns :map

      run fn _input, context ->
        with {:ok, current} <-
               Ash.get(__MODULE__, Map.get(context.actor, :nvr_storage_id),
                 actor: context.actor,
                 not_found_error?: false
               ) do
          current_status(current, context.actor)
        end
      end
    end
  end

  policies do
    policy action_type(:create) do
      forbid_unless actor_attribute_equals(:role, :system)
      forbid_unless actor_attribute_equals(:nvr_storage_purpose, :qualify)
      authorize_if expr(storage_id == ^actor(:nvr_storage_id))
    end

    policy action(:status) do
      forbid_unless actor_attribute_equals(:role, :system)
      authorize_if actor_attribute_equals(:nvr_storage_purpose, :qualify)
    end

    policy action_type(:read) do
      forbid_unless actor_attribute_equals(:role, :system)
      forbid_unless actor_attribute_equals(:nvr_storage_purpose, :qualify)
      authorize_if expr(storage_id == ^actor(:nvr_storage_id))
    end
  end

  attributes do
    attribute :storage_id, :uuid, primary_key?: true, allow_nil?: false

    attribute :revision, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :state, :atom, allow_nil?: false, constraints: [one_of: [:active, :withdrawn]]
    attribute :qualification_report_id, :uuid
    attribute :health, :map, sensitive?: true
    attribute :policy, :map

    attribute :reason, :string,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/]

    attribute :decision_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :decided_by, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128, match: ~r/\A[!-~]+\z/]

    attribute :decided_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :qualification_report, LocalStorageQualificationReport, define_attribute?: false
  end

  defp current_status(nil, _actor), do: {:ok, %{qualification_status: :unknown}}

  defp current_status(%{state: :withdrawn} = current, _actor),
    do: {:ok, %{qualification_status: :withdrawn, revision: current.revision}}

  defp current_status(current, actor) do
    policy = Map.get(actor, :nvr_storage_policy)

    with {:ok, snapshot} <- LocalStorageEvidence.policy_snapshot(policy),
         true <- snapshot == current.policy,
         {:ok, report} <-
           Ash.get(LocalStorageQualificationReport, current.qualification_report_id, actor: actor) do
      result =
        LocalStorageEvidence.evaluate(
          report,
          policy,
          current.health,
          System.system_time(:millisecond)
        )

      status = if result.evidence_status == :current, do: :qualified, else: :ineligible
      {:ok, Map.merge(result, %{qualification_status: status, revision: current.revision})}
    else
      false ->
        {:ok,
         %{qualification_status: :ineligible, reason: :policy_changed, revision: current.revision}}

      {:error, :invalid_policy} ->
        {:ok,
         %{qualification_status: :ineligible, reason: :invalid_policy, revision: current.revision}}

      {:error, error} ->
        {:error, error}
    end
  end
end
