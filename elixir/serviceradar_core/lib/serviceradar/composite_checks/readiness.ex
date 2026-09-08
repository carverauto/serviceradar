defmodule ServiceRadar.CompositeChecks.Readiness do
  @moduledoc """
  Decides whether a composite check is safe to enable, and explains why not.

  Two properties are enforced here rather than left to the operator:

  **Liveness witness.** A check with two or more vantage points must expect at
  least one of them to reach the device. Without a witness, "blocked from
  everywhere" is the expected pattern, and a powered-off device satisfies it
  perfectly — the check would certify dead devices as compliant. This is the
  single most important correctness property of a multi-vantage-point check.

  **Coverage.** Because composite checks derive rather than probe, a vantage
  point with no underlying sweep produces `inconclusive` forever while the check
  looks perfectly healthy. Zero coverage blocks enabling unless the operator
  explicitly acknowledges the gap.

  Returns structured problems rather than a boolean so the builder can render
  each one in place.
  """

  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.Coverage

  @type problem :: %{code: atom(), message: String.t()}
  @type report :: %{blocking: [problem()], warnings: [problem()], coverage: [map()]}

  @spec check(struct(), keyword()) :: {:ok, report()} | {:error, term()}
  def check(check, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, inputs} <- CompositeCheckInput.list_by_check(check.id, actor: actor),
         {:ok, coverage} <- Coverage.for_check(check, inputs, opts) do
      vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

      blocking =
        witness_problem(vantage_points) ++ Enum.flat_map(coverage, &zero_coverage_problem/1)

      warnings = Enum.flat_map(coverage, &partial_coverage_problem/1)

      {:ok, %{blocking: blocking, warnings: warnings, coverage: coverage}}
    end
  end

  defp witness_problem(vantage_points) when length(vantage_points) < 2, do: []

  defp witness_problem(vantage_points) do
    if Enum.any?(vantage_points, &(&1.expected == "available")) do
      []
    else
      [
        %{
          code: :no_liveness_witness,
          message:
            "At least one vantage point must be expected to reach the device. Without a " <>
              "liveness witness, a powered-off device is indistinguishable from a perfectly " <>
              "isolated one."
        }
      ]
    end
  end

  defp zero_coverage_problem(%{covered: 0, total: total, agent_id: agent_id}) when total > 0 do
    [
      %{
        code: :no_coverage,
        message:
          "No sweep from #{agent_id} covers this scope: 0 of #{total} devices have results. " <>
            "Every device will evaluate as inconclusive."
      }
    ]
  end

  defp zero_coverage_problem(_row), do: []

  defp partial_coverage_problem(%{covered: covered, total: total, agent_id: agent_id})
       when covered > 0 and covered < total do
    [
      %{
        code: :partial_coverage,
        message:
          "#{agent_id} has results for #{covered} of #{total} devices in scope. " <>
            "The remaining #{total - covered} will evaluate as inconclusive."
      }
    ]
  end

  defp partial_coverage_problem(_row), do: []
end
