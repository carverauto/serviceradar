defmodule ServiceRadar.Plugins.RolloutArtifact do
  @moduledoc """
  What a fleet rollout needs to know about the artifact it moves.

  `ServiceRadar.Plugins.AddonRolloutCoordinator` owns the rollout state machine:
  the rollout and target rows, batching, soak, deadlines, pause/resume/cancel,
  supersession, rollback and slot release. `ServiceRadar.Plugins.AddonRolloutEligibility`
  owns semantic-version candidate selection and agent availability. Neither knows
  which resource holds an artifact's packages, sources, per-agent desired state or
  health evidence. An implementation of this behaviour supplies exactly that.

  The coordinator relies on a small shape contract alongside the callbacks:

    * a package has `:id` and `:version`;
    * a source has `:id` and `:rollout_policy`;
    * a member (the per-agent desired-state row a target overrides) has `:id`
      and `:agent_uid`.

  Rollout and target rows record the `artifact_kind` of the implementation that
  owns them. The coordinator reads only rows whose kind has an implementation in
  `implementations/0`. Only `:native_addon` has one today, so `implementation/1`
  has one answer and a `:wasm_plugin` row is invisible to the coordinator.
  """

  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutArtifact
  alias ServiceRadar.Plugins.AddonRolloutTarget

  @type actor :: term()
  @type package :: %{
          required(:id) => term(),
          required(:version) => String.t(),
          optional(atom()) => term()
        }
  @type source :: %{
          required(:id) => term(),
          required(:rollout_policy) => map() | nil,
          optional(atom()) => term()
        }
  @type member :: %{
          required(:id) => term(),
          required(:agent_uid) => String.t(),
          optional(atom()) => term()
        }
  @type evidence :: term()

  @doc "The `artifact_kind` recorded on this implementation's rollouts and targets."
  @callback artifact_kind() :: atom()

  # Sources and their stable package.

  @doc "Enabled sources that track the latest approved package and are not explicitly pinned."
  @callback managed_sources(actor()) :: {:ok, [source()]} | {:error, term()}

  @doc """
  Moves sources that were left on a manual pin nobody chose back to managed
  updates. Returns how many sources it changed.
  """
  @callback restore_managed_sources([package()], actor()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc "The `source_type` a rollout records for this source."
  @callback source_type(source()) :: atom()

  @doc "Re-reads the source a rollout was created for."
  @callback source_for_rollout(AddonRollout.t(), actor()) :: {:ok, source()} | {:error, term()}

  @doc "The id of the stable package the source currently runs."
  @callback stable_package_id(source()) :: term()

  # Packages.

  @callback list_packages(actor()) :: {:ok, [package()]} | {:error, term()}
  @callback get_package(id :: term(), actor()) :: {:ok, package()} | {:error, term()}
  @callback packages_by_id([term()], actor()) :: {:ok, [package()]} | {:error, term()}

  @doc "The artifact identifier a rollout records (`addon_id`)."
  @callback artifact_id(package()) :: String.t()

  # Candidate eligibility, consulted by AddonRolloutEligibility.

  @doc "Whether `candidate` is a later release of the same artifact from the same origin."
  @callback same_lineage?(candidate :: package(), current :: package()) :: boolean()

  @doc "Whether the package's approval and provenance make it a candidate at all."
  @callback trusted_approved?(package()) :: boolean()

  @doc "Whether the package's approved capabilities stay inside the source's ceiling."
  @callback within_capability_ceiling?(package(), source() | map()) :: boolean()

  @doc "Why `agent` cannot run `package`, or nil when it can."
  @callback incompatibility(package(), agent :: map()) :: String.t() | nil

  # Target materialization.

  @doc "The members a source rolls the candidate out to."
  @callback source_members(source(), actor()) :: {:ok, [member()]} | {:error, term()}

  @doc "Ids of members whose agent has a direct source that takes precedence over this one."
  @callback overridden_members(source(), [member()], actor()) ::
              {:ok, MapSet.t()} | {:error, term()}

  @doc "Member-derived attributes of a new target row."
  @callback target_attrs(member(), previous :: package()) :: map()

  # Overrides and promotion.

  @callback apply_override(AddonRolloutTarget.t(), AddonRollout.t(), DateTime.t(), actor()) ::
              :ok | {:error, term()}

  @doc "Removes the target's override, if this rollout still owns it."
  @callback clear_override(AddonRolloutTarget.t(), actor()) :: :ok | {:error, term()}

  @doc "Whether the rollout's source may absorb rolled-back members up to the policy tolerance."
  @callback tolerates_failures?(AddonRollout.t()) :: boolean()

  @doc "Detaches a tolerated rolled-back member so it stays on its previous package."
  @callback pin_failed_member(AddonRolloutTarget.t(), actor()) :: :ok | {:error, term()}

  @doc "Moves the rollout's source to the candidate as its stable package."
  @callback promote_source(AddonRollout.t(), actor()) :: :ok | {:error, term()}

  # Health evidence.

  @doc "The latest evidence for each target, keyed by agent uid."
  @callback load_evidence([AddonRolloutTarget.t()], AddonRollout.t(), actor()) ::
              %{optional(String.t()) => evidence()}

  @callback observed_at(evidence()) :: DateTime.t() | nil

  @doc "Fresh evidence, reported since `applied_at`, that the candidate came up."
  @callback candidate_ready?(evidence() | nil, package(), applied_at :: DateTime.t() | nil) ::
              boolean()

  @doc "Fresh evidence, reported since `applied_at`, that the candidate itself failed."
  @callback candidate_failed?(evidence() | nil, package(), applied_at :: DateTime.t() | nil) ::
              boolean()

  @doc "Fresh evidence, reported since `since`, that the previous package is running again."
  @callback recovered?(evidence() | nil, previous :: package(), since :: DateTime.t() | nil) ::
              boolean()

  @doc "Whether the evidence shows the candidate or a later version running."
  @callback converged?(evidence() | nil, package()) :: boolean()

  # Audit and telemetry.

  @callback audit_resource_type() :: String.t()
  @callback telemetry_event() :: [atom()]

  @doc "The implementation for a rollout, one of its sources, or one of its packages."
  @spec implementation(term()) :: module()
  def implementation(_rollout_source_or_package), do: AddonRolloutArtifact

  @doc "Every implementation, for work that spans all rollouts."
  @spec implementations() :: [module()]
  def implementations, do: [AddonRolloutArtifact]

  @doc "The artifact kinds that have an implementation."
  @spec kinds() :: [atom()]
  def kinds, do: Enum.map(implementations(), & &1.artifact_kind())
end
