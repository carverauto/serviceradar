defmodule ServiceradarSecret.Manifest do
  @moduledoc """
  The logical secret names a component declares.

  The provider refuses anything undeclared. Configuration gets least privilege from the build
  graph -- a target that does not declare a section cannot see it -- but a secret cannot be a
  build target, so the symmetric mechanism is this declaration, enforced at the provider.
  """

  defstruct names: MapSet.new()

  @type t :: %__MODULE__{names: MapSet.t(String.t())}

  @spec new(Enumerable.t()) :: t()
  def new(names \\ []), do: %__MODULE__{names: MapSet.new(names)}

  @spec declares?(t(), String.t()) :: boolean()
  def declares?(%__MODULE__{names: names}, name), do: MapSet.member?(names, name)

  @doc "Every declared name, sorted, so a refusal is stable and diffable."
  @spec declared(t()) :: [String.t()]
  def declared(%__MODULE__{names: names}), do: names |> MapSet.to_list() |> Enum.sort()

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{names: names}), do: MapSet.size(names) == 0
end
