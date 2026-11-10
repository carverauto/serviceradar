defmodule ServiceRadar.Edge.RecoveryEffect do
  @moduledoc "The consumer effect required by a frozen classification and historical lookup outcome."

  @enforce_keys [:state, :outcome, :fence?, :range?, :retry?]
  defstruct [:state, :outcome, :fence?, :range?, :retry?, :mapping_value]

  @doc "Keeps delivery loss, produced-range loss and unresolved historical authority distinct."
  def classify(:unattributable, :not_looked_up),
    do: {:ok, effect(:applied, :unattributable, true, false, true)}

  def classify(kind, lookup) when kind in [:attributed_active, :attributed_passive] do
    case lookup do
      {:found, value} ->
        resolved(kind, :found, value)

      {:not_scheduled, value} ->
        resolved(kind, :not_scheduled, value)

      :temporarily_unavailable ->
        {:ok, effect(:pending, :temporarily_unavailable, false, false, false)}

      :missing ->
        {:ok, effect(:blocked, :missing, true, false, false)}

      :corrupt ->
        {:ok, effect(:blocked, :corrupt, false, false, false)}

      :conflicting ->
        {:ok, effect(:blocked, :conflicting, false, false, false)}

      _ ->
        {:error, :mapping_lookup_contract}
    end
  end

  def classify(_, _), do: {:error, :classification}

  defp resolved(kind, outcome, value) do
    active? = kind == :attributed_active
    {:ok, %{effect(:applied, outcome, false, active?, active?) | mapping_value: value}}
  end

  defp effect(state, outcome, fence?, range?, retry?),
    do: %__MODULE__{
      state: state,
      outcome: outcome,
      fence?: fence?,
      range?: range?,
      retry?: retry?
    }
end
