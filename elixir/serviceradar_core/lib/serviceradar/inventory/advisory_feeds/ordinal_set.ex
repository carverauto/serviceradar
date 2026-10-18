defmodule ServiceRadar.Inventory.AdvisoryFeeds.OrdinalSet do
  @moduledoc """
  The set of advisory ordinals one feed run has observed.

  A complete feed run must know every advisory it saw, including the unchanged
  ones it skips, so that finalization can withdraw exactly the current
  advisories absent from the snapshot. That set used to be one presence row per
  source object per run: ~409k rows of WAL for every nist-nvd2 run, even when
  nothing changed. It is now held in memory for the duration of the run.

  The representation is a bitmap split into 32-bit words keyed by
  `ordinal >>> 5`, in the spirit of a roaring bitmap's bitmap containers.
  Ordinals come from one bigint sequence on `vulnerability_advisories` and are
  dense within a feed, so a full nist-nvd2 run is ~13k map entries (~0.4 MB)
  where a `MapSet` of the same integers is ~11.5 MB; the bitmap also builds in
  half the time. Words stay at 32 bits so each one is an immediate small
  integer on a 64-bit BEAM rather than a heap bignum. Sparse ordinals degrade
  gracefully to one word per ordinal.

  The set is a plain value: runs are single-flight and the set never leaves the
  process that loads the feed.
  """

  import Bitwise

  @word_shift 5
  @word_mask (1 <<< @word_shift) - 1

  @enforce_keys [:words, :size]
  defstruct words: %{}, size: 0

  @type t :: %__MODULE__{
          words: %{optional(non_neg_integer()) => non_neg_integer()},
          size: non_neg_integer()
        }

  @doc "An empty set."
  @spec new() :: t()
  def new, do: %__MODULE__{words: %{}, size: 0}

  @doc "Add one ordinal; adding an ordinal already present leaves the set unchanged."
  @spec put(t(), non_neg_integer()) :: t()
  def put(%__MODULE__{words: words, size: size} = set, ordinal)
      when is_integer(ordinal) and ordinal >= 0 do
    key = ordinal >>> @word_shift
    bit = 1 <<< (ordinal &&& @word_mask)

    case Map.fetch(words, key) do
      {:ok, word} when (word &&& bit) != 0 -> set
      {:ok, word} -> %{set | words: Map.put(words, key, word ||| bit), size: size + 1}
      :error -> %{set | words: Map.put(words, key, bit), size: size + 1}
    end
  end

  @doc "Add every ordinal in `ordinals`."
  @spec put_all(t(), Enumerable.t()) :: t()
  def put_all(%__MODULE__{} = set, ordinals), do: Enum.reduce(ordinals, set, &put(&2, &1))

  @doc "True when `ordinal` was added."
  @spec member?(t(), integer()) :: boolean()
  def member?(%__MODULE__{words: words}, ordinal) when is_integer(ordinal) and ordinal >= 0 do
    case Map.fetch(words, ordinal >>> @word_shift) do
      {:ok, word} -> (word &&& 1 <<< (ordinal &&& @word_mask)) != 0
      :error -> false
    end
  end

  def member?(%__MODULE__{}, _ordinal), do: false

  @doc "Number of distinct ordinals added."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size
end
