defmodule ServiceRadar.Edge.PlanValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.ValidatePlanHeader` / `ValidatePlanPages`.

  It exists because deriving assignment authority from an UNVALIDATED plan is not a
  weaker check, it is no check: an attacker who supplies the plan chooses the range
  digests, the windows, and therefore the expectation the assignment is compared
  against. Before this module, mutating `page_sha256`, `page_index`, or both the
  header and assignment plan hashes still yielded `:ok` from the relational
  validator, because only the MTR window walk ran.

  `validate/2` returns an opaque `{:ok, validated}` carrier. `AssignmentValidate`
  accepts ONLY that carrier, so "I forgot to validate the plan" is not expressible at
  the call site rather than merely discouraged.
  """

  alias ServiceRadar.Edge.HashGrammar

  @sha256_len 32
  @uuid_len 16
  @max_policy_id_bytes 128

  @opaque validated :: {__MODULE__, map(), [map()], %{binary() => non_neg_integer()}}

  @type reason ::
          :header_identity
          | :header_digest
          | :page_digest
          | :page_chain
          | :plan_root
          | :mtr_commitment
          | :mtr_window

  @doc """
  Fail-close a plan header and its page chain, returning the opaque validated carrier
  plus each range's plan-global ordinal window.
  """
  @spec validate(map(), [map()]) :: {:ok, validated()} | {:error, reason()}
  def validate(header, pages) when is_map(header) and is_list(pages) do
    with :ok <- header_identity(header),
         :ok <- page_chain(header, pages),
         :ok <- plan_root(header, pages),
         {:ok, windows, _total} <- compute_windows(pages),
         :ok <- mtr_commitment(header, pages),
         # The header self-hash is checked LAST so a mismatch is reported as a digest
         # failure only when every field it covers is otherwise coherent.
         :ok <- header_digest(header) do
      {:ok, {__MODULE__, header, pages, windows}}
    end
  end

  @doc "The validated header."
  @spec header(validated()) :: map()
  def header({__MODULE__, h, _pages, _windows}), do: h

  @doc "Each range's plan-global ordinal window offset, keyed by range id."
  @spec windows(validated()) :: %{binary() => non_neg_integer()}
  def windows({__MODULE__, _h, _pages, w}), do: w

  @doc "Find a committed range by id, or nil."
  @spec find_range(validated(), binary()) :: map() | nil
  def find_range({__MODULE__, _h, pages, _w}, range_id) do
    pages |> Enum.flat_map(& &1.ranges) |> Enum.find(&(&1.range_id == range_id))
  end

  defp header_identity(h) do
    policy_len = byte_size(Map.get(h, :availability_policy_id) || <<>>)

    if uuidv7?(Map.get(h, :execution_plan_id)) and
         Map.get(h, :digest_version) == 1 and
         digest?(Map.get(h, :plan_root_sha256)) and
         digest?(Map.get(h, :check_set_sha256)) and
         canonical_uuid?(Map.get(h, :network_scope_id)) and
         policy_len > 0 and policy_len <= @max_policy_id_bytes and
         (Map.get(h, :page_count) || 0) > 0 and
         digest?(Map.get(h, :mtr_ordinal_range_commitment)) do
      :ok
    else
      {:error, :header_identity}
    end
  end

  defp header_digest(h) do
    if HashGrammar.plan_header_digest(h) == Map.get(h, :execution_plan_sha256),
      do: :ok,
      else: {:error, :header_digest}
  end

  defp page_chain(h, pages) do
    plan_id = Map.get(h, :execution_plan_id)
    count = Map.get(h, :page_count)

    pages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {p, i}, :ok ->
      prev = if i == 0, do: <<>>, else: Enum.at(pages, i - 1).page_sha256

      cond do
        p.execution_plan_id != plan_id -> {:halt, {:error, :page_chain}}
        p.page_index != i -> {:halt, {:error, :page_chain}}
        p.page_count != count -> {:halt, {:error, :page_chain}}
        p.check_set_sha256 != Map.get(h, :check_set_sha256) -> {:halt, {:error, :page_chain}}
        (p.prev_page_sha256 || <<>>) != prev -> {:halt, {:error, :page_chain}}
        HashGrammar.plan_page_digest(p) != p.page_sha256 -> {:halt, {:error, :page_digest}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp plan_root(h, pages) do
    if HashGrammar.plan_root(pages) == Map.get(h, :plan_root_sha256),
      do: :ok,
      else: {:error, :plan_root}
  end

  defp compute_windows(pages) do
    case HashGrammar.plan_mtr_windows(pages) do
      :error -> {:error, :mtr_window}
      ok -> ok
    end
  end

  defp mtr_commitment(h, pages) do
    case HashGrammar.plan_mtr_ordinal_range_commitment(pages) do
      :error ->
        {:error, :mtr_window}

      {:ok, want} ->
        if want == Map.get(h, :mtr_ordinal_range_commitment),
          do: :ok,
          else: {:error, :mtr_commitment}
    end
  end

  # Mirrors Go's ValidateCanonicalUUID: 16 bytes AND not the all-zero value, which is
  # "unset" wearing an identifier's shape.
  @doc false
  def canonical_uuid?(v), do: is_binary(v) and byte_size(v) == @uuid_len and v != <<0::128>>

  @doc false
  def uuidv7?(<<_::48, ver::4, _::12, var::2, _::62>> = v) when ver == 7 and var == 2,
    do: canonical_uuid?(v)

  def uuidv7?(_), do: false

  defp digest?(v), do: is_binary(v) and byte_size(v) == @sha256_len
end
