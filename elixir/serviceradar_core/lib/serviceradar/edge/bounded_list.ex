defmodule ServiceRadar.Edge.BoundedList do
  @moduledoc """
  Counting a list WITHOUT traversing more of it than the ceiling permits (task 1.5-h).

  `length/1` walks the whole list. A count ceiling exists to stop unbounded work, so comparing
  `length(list) > cap` performs exactly the traversal the ceiling forbids: a ten-million-element
  list is walked in full to discover it is too long. The verdict is correct, which is why no
  verdict-only vector detects it -- the bound and the bounded walk return the same answer, and
  differ only in what they cost.

  This walks at most `cap + 1` cells. The extra cell is what distinguishes "exactly cap" from
  "more than cap"; stopping at `cap` could not tell them apart.

  It also reports an IMPROPER list rather than raising. These validators take decoded structs
  whose fields are supposed to be lists, and a hand-built map can carry any term; a
  `FunctionClauseError` from a counting helper would surface as a crash where the caller has a
  vocabulary for malformed input.
  """

  @typedoc "A bounded count, an over-cap signal, or a list that never terminated properly."
  @type outcome :: {:ok, non_neg_integer()} | :over | :improper

  @doc """
  Counts `list`, walking at most `cap + 1` elements.

  Returns `{:ok, n}` when the list holds `n <= cap` elements, `:over` as soon as element
  `cap + 1` is reached, and `:improper` for a non-list tail.
  """
  @spec count_at_most(term(), non_neg_integer()) :: outcome()
  def count_at_most(list, cap) when is_integer(cap) and cap >= 0, do: walk(list, cap, 0)

  # The over-cap guard comes FIRST. Behind the empty-list clause it never fires for a list of
  # exactly cap+1: the walk consumes the last element, sees `[]`, and reports {:ok, cap+1}.
  defp walk(_l, cap, n) when n > cap, do: :over
  defp walk([], _cap, n), do: {:ok, n}
  defp walk([_ | t], cap, n), do: walk(t, cap, n + 1)
  defp walk(_improper_tail, _cap, _n), do: :improper

  @doc """
  Counts `list` with NO ceiling, reporting `:improper` instead of raising.

  DELIBERATELY UNBOUNDED. It exists for the shape question a bounded count cannot answer:
  whether a list terminates properly. `is_list([1 | :tail])` is true and `Enum.reduce_while/3`
  then raises on the tail, so a validator promising `{:error, reason}` must walk to the tail
  before doing element work.

  NOT EVERY CALLER IS BEHIND A CEILING, so this is not safe by construction -- it is safe only
  where the caller has established one. A caller that has NOT bounded its input wants
  `count_at_most/2`; reaching for this instead reintroduces exactly the unbounded traversal the
  ceilings exist to prevent.
  """
  @spec count_all(term()) :: {:ok, non_neg_integer()} | :improper
  def count_all(list), do: walk_unbounded(list, 0)

  defp walk_unbounded([], n), do: {:ok, n}
  defp walk_unbounded([_ | t], n), do: walk_unbounded(t, n + 1)
  defp walk_unbounded(_improper_tail, _n), do: :improper

  @doc """
  True when `list` holds at most `cap` elements, walking at most `cap + 1` of them.

  An improper list is NOT within the bound -- it has no length to be within one.
  """
  @spec within?(term(), non_neg_integer()) :: boolean()
  def within?(list, cap), do: match?({:ok, _}, count_at_most(list, cap))

  @doc """
  True when `list` holds between `1` and `cap` elements inclusive.

  The common shape for a page or span list, where an empty collection has no derivable extent.
  """
  @spec nonempty_within?(term(), non_neg_integer()) :: boolean()
  def nonempty_within?(list, cap), do: match?({:ok, n} when n >= 1, count_at_most(list, cap))
end
