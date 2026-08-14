defmodule ServiceRadar.CompositeChecks.Validations.EnforceReadiness do
  @moduledoc """
  Blocks enabling a composite check that cannot produce meaningful verdicts.

  Coverage gaps are acknowledgeable — an operator may knowingly enable a check
  ahead of the sweep that will feed it. A missing liveness witness is not: it is
  a correctness fault, not a timing one, and a check without a witness would
  certify powered-off devices as compliant.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.CompositeChecks.Readiness

  @impl true
  def atomic(changeset, opts, context) do
    case validate(changeset, opts, context) do
      :ok -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def validate(changeset, _opts, context) do
    acknowledged? = Ash.Changeset.get_argument(changeset, :acknowledge_coverage_gap)

    case Readiness.check(changeset.data, actor: context.actor) do
      {:ok, %{blocking: blocking}} ->
        blocking
        |> Enum.reject(&(acknowledged? and &1.code == :no_coverage))
        |> first_problem()

      {:error, reason} ->
        {:error, field: :state, message: "could not evaluate readiness: #{inspect(reason)}"}
    end
  end

  defp first_problem([]), do: :ok
  defp first_problem([problem | _rest]), do: {:error, field: :state, message: problem.message}
end
