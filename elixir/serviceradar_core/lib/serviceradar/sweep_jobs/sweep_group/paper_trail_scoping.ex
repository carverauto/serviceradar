defmodule ServiceRadar.SweepJobs.SweepGroup.PaperTrailScoping do
  @moduledoc """
  Scopes SweepGroup paper-trail versioning to explicitly versioned actions.

  `AshPaperTrail.Resource.Transformers.VersionOnChange` installs its
  `CreateNewVersion` change on every create/update/destroy action, and under
  `change_tracking_mode :full_diff` that change reports every action as
  non-atomic -- including `run_now` and `record_execution`, which are excluded
  from versioning via `on_actions` but still fail `fully_atomic_changeset`
  (and fail outright at runtime when the action requires atomic updates).

  This extension removes that global change. Each action that must write
  versions (`create`, `update`, `enable`, `disable`, `destroy`) declares
  `change AshPaperTrail.Resource.Changes.CreateNewVersion` locally instead, so
  the per-run execution actions stay atomic. If the extension ever stops
  installing the global change, the removal matches nothing and the local
  changes keep working; the `run_now` atomicity guard in
  `DispatchSweepRunTest` catches a regression.
  """

  use Spark.Dsl.Extension, transformers: [__MODULE__.Transformer]

  defmodule Transformer do
    @moduledoc false
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer

    @impl true
    def after?(AshPaperTrail.Resource.Transformers.VersionOnChange), do: true
    def after?(_), do: false

    @impl true
    def transform(dsl_state) do
      {:ok,
       Transformer.remove_entity(dsl_state, [:changes], fn
         %{change: {AshPaperTrail.Resource.Changes.CreateNewVersion, _}} -> true
         _ -> false
       end)}
    end
  end
end
