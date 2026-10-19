defmodule ServiceRadar.Inventory.Availability.AuthorityClass do
  @moduledoc """
  The ranked authority classes of device availability evidence
  (`add-merged-device-availability`, design Decision 2).

  A class says how much a source knows about a device's operational state, never which
  integration it is. Rank 1 is the strongest. `self_report` and `passive_observation`
  assert only `up`: they retire by expiring, never by submitting `down`.
  """

  @classes [
    :operator_policy,
    :self_report,
    :managing_controller,
    :active_probe,
    :passive_observation,
    :inventory_declared
  ]

  @up_only [:self_report, :passive_observation]

  # The active_probe threshold is the sweep ingestor's @unavailable_threshold. Every other
  # class that may assert `down` is decisive on its first observation.
  @confirmation_thresholds %{active_probe: 2}

  @type t ::
          :operator_policy
          | :self_report
          | :managing_controller
          | :active_probe
          | :passive_observation
          | :inventory_declared

  @doc "Every class, strongest first."
  @spec all() :: [t()]
  def all, do: @classes

  @doc "The class a source that declares none is treated as."
  @spec undeclared() :: t()
  def undeclared, do: :inventory_declared

  @doc """
  Parses a declared class. Accepts the atom or its string form; anything else is
  `:error`, so a typo in a manifest or registration is never read as a real class.
  """
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(class) when class in @classes, do: {:ok, class}

  def cast(class) when is_binary(class) do
    case Enum.find(@classes, &(Atom.to_string(&1) == String.trim(class))) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  def cast(_class), do: :error

  @doc "1 for the strongest class."
  @spec rank(t()) :: pos_integer()
  def rank(class), do: Enum.find_index(@classes, &(&1 == class)) + 1

  @spec up_only?(t()) :: boolean()
  def up_only?(class), do: class in @up_only

  @doc "Consecutive `down` observations needed before a `down` record is decisive."
  @spec confirmation_threshold(t()) :: pos_integer()
  def confirmation_threshold(class), do: Map.get(@confirmation_thresholds, class, 1)

  @doc """
  The class an instance ends up with: the type's declared class, lowered by the
  instance's own class when that is weaker. An instance can never raise its type.
  """
  @spec lower(t(), t() | nil) :: t()
  def lower(declared, nil), do: declared

  def lower(declared, instance) do
    if rank(instance) > rank(declared), do: instance, else: declared
  end
end
