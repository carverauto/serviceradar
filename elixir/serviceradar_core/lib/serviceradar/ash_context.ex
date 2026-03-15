defmodule ServiceRadar.AshContext do
  @moduledoc false

  @spec actor(term()) :: term() | nil
  def actor(%Ash.Changeset{context: context}), do: actor(context)
  def actor(%{private: %{actor: actor}}), do: actor
  def actor(%{actor: actor}), do: actor
  def actor(_), do: nil
end
