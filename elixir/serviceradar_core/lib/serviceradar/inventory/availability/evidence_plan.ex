defmodule ServiceRadar.Inventory.Availability.EvidencePlan do
  @moduledoc """
  Pure planning for availability evidence writes (design Decisions 4 and 7).

  `build/3` turns a submitted observation into a row against its source registration:
  the class comes from the registration (lowered, never raised, by the instance), the
  TTL is bounded by it, and `observed_at` is clamped to `[now - max_ttl, now]`.

  `merge/3` decides whether that row must be written over the stored one. Decision-bearing
  changes are written at once; an unchanged observation only renews the lease once less
  than half of it remains, so a steady source writes about twice per TTL.

  Coalescing means a stored `up` can be older than the source's latest `up`. A `down`
  observed within half a lease of the stored `up` may therefore be older than an `up`
  that was coalesced away. Such a flip is written as usual and marked in its `detail`
  under `"coalesced_flip"` so it remains identifiable.
  """

  alias ServiceRadar.Inventory.Availability.AuthorityClass
  alias ServiceRadar.Inventory.Availability.Sources

  @coalesced_flip_key "coalesced_flip"

  # The column allows 2 KB of jsonb text, which spaces keys and values more widely
  # than Jason does; half of it leaves room for that.
  @max_detail_bytes 1_024

  @type row :: %{
          device_uid: String.t(),
          source_kind: String.t(),
          source_instance: String.t(),
          reporter_agent_id: String.t(),
          authority_class: String.t(),
          state: String.t(),
          observed_at: DateTime.t(),
          expires_at: DateTime.t(),
          state_since: DateTime.t(),
          confirmations: pos_integer(),
          reporter_eligible: boolean(),
          detail: map()
        }

  @doc """
  Builds the row for one submitted observation.

  The submission is a map with `:device_uid`, `:state` (`:up` or `:down`) and
  `:observed_at`, and optionally `:source_instance`, `:reporter_agent_id`,
  `:ttl_seconds`, `:instance_class`, `:reporter_eligible` and `:detail`. A `down`
  observation from an up-only class is rejected: such a source retires by expiring.
  """
  @spec build(map(), Sources.t(), DateTime.t()) :: {:ok, row()} | {:error, atom()}
  def build(submission, %Sources{} = source, now) do
    with {:ok, device_uid} <- device_uid(submission),
         {:ok, state} <- state(submission),
         {:ok, class} <- class(source, submission),
         :ok <- assertable(class, state),
         {:ok, observed_at} <- observed_at(submission) do
      ttl = ttl(submission, source)
      observed_at = clamp_observed_at(observed_at, now, source.max_ttl)

      {:ok,
       %{
         device_uid: device_uid,
         source_kind: source.kind,
         source_instance: text(submission, :source_instance),
         reporter_agent_id: text(submission, :reporter_agent_id),
         authority_class: Atom.to_string(class),
         state: Atom.to_string(state),
         observed_at: observed_at,
         expires_at: DateTime.shift(observed_at, second: ttl),
         state_since: observed_at,
         confirmations: 1,
         reporter_eligible: Map.get(submission, :reporter_eligible, true) != false,
         detail: bounded_detail(Map.get(submission, :detail))
       }}
    end
  end

  @doc """
  Whether `row` must be written over `existing` (nil when there is none), and the row to
  write. An observation older than the stored one is skipped so a replay cannot regress
  the record. The confirmation count and `state_since` carry over from the stored record
  while the state holds.
  """
  @spec merge(map() | nil, row(), DateTime.t()) :: {:write, row()} | :skip
  def merge(nil, row, _now), do: {:write, row}

  def merge(existing, row, now) do
    if DateTime.before?(row.observed_at, existing.observed_at) do
      :skip
    else
      merged = existing |> carry_over(row) |> mark_coalesced_flip(existing)

      if decision_bearing?(existing, merged) or lease_due?(existing, merged, now),
        do: {:write, merged},
        else: :skip
    end
  end

  defp carry_over(existing, row) do
    if existing.state == row.state do
      class = class_atom(row.authority_class)
      advance = if DateTime.after?(row.observed_at, existing.observed_at), do: 1, else: 0

      confirmations =
        min(existing.confirmations + advance, AuthorityClass.confirmation_threshold(class))

      %{row | state_since: existing.state_since, confirmations: max(confirmations, 1)}
    else
      row
    end
  end

  @doc "The `detail` key that marks a flip to `down` inside the coalescing window."
  @spec coalesced_flip_key() :: String.t()
  def coalesced_flip_key, do: @coalesced_flip_key

  defp mark_coalesced_flip(%{state: "down"} = row, %{state: "up"} = existing) do
    half_lease = div(DateTime.diff(existing.expires_at, existing.observed_at, :millisecond), 2)

    if DateTime.before?(
         row.observed_at,
         DateTime.add(existing.observed_at, half_lease, :millisecond)
       ) do
      flip = %{"previous_up_observed_at" => DateTime.to_iso8601(existing.observed_at)}
      %{row | detail: Map.put(row.detail, @coalesced_flip_key, flip)}
    else
      row
    end
  end

  defp mark_coalesced_flip(row, _existing), do: row

  defp decision_bearing?(existing, row) do
    existing.state != row.state or
      existing.authority_class != row.authority_class or
      existing.reporter_eligible != row.reporter_eligible or
      DateTime.before?(row.expires_at, existing.expires_at) or
      existing.confirmations < row.confirmations
  end

  defp lease_due?(existing, row, now) do
    lease = DateTime.diff(row.expires_at, row.observed_at, :millisecond)
    remaining = DateTime.diff(existing.expires_at, now, :millisecond)
    remaining * 2 < lease
  end

  defp device_uid(submission) do
    case Map.get(submission, :device_uid) do
      uid when is_binary(uid) and uid != "" -> {:ok, uid}
      _ -> {:error, :missing_device_uid}
    end
  end

  defp state(submission) do
    case Map.get(submission, :state) do
      state when state in [:up, :down] -> {:ok, state}
      _ -> {:error, :invalid_state}
    end
  end

  defp class(source, submission) do
    case Map.get(submission, :instance_class) do
      nil ->
        {:ok, source.authority_class}

      instance ->
        case AuthorityClass.cast(instance) do
          {:ok, instance} -> {:ok, AuthorityClass.lower(source.authority_class, instance)}
          :error -> {:error, :invalid_instance_class}
        end
    end
  end

  defp assertable(class, :down) do
    if AuthorityClass.up_only?(class), do: {:error, :up_only_class}, else: :ok
  end

  defp assertable(_class, :up), do: :ok

  defp observed_at(submission) do
    case Map.get(submission, :observed_at) do
      %DateTime{} = at -> {:ok, microsecond_precision(at)}
      _ -> {:error, :missing_observed_at}
    end
  end

  # The columns are microsecond timestamps, and Ecto rejects a coarser DateTime.
  defp microsecond_precision(at) do
    %DateTime{microsecond: {microsecond, _precision}} = at = DateTime.truncate(at, :microsecond)
    %{at | microsecond: {microsecond, 6}}
  end

  defp clamp_observed_at(observed_at, now, max_ttl) do
    now = microsecond_precision(now)
    floor = DateTime.shift(now, second: -max_ttl)

    cond do
      DateTime.after?(observed_at, now) -> now
      DateTime.before?(observed_at, floor) -> floor
      true -> observed_at
    end
  end

  defp ttl(submission, source) do
    case Map.get(submission, :ttl_seconds) do
      ttl when is_integer(ttl) -> ttl |> max(source.min_ttl) |> min(source.max_ttl)
      _ -> source.default_ttl
    end
  end

  defp text(submission, key) do
    case Map.get(submission, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp bounded_detail(detail) when is_map(detail) do
    case Jason.encode(detail) do
      {:ok, json} when byte_size(json) <= @max_detail_bytes -> detail
      _ -> %{"truncated" => true}
    end
  end

  defp bounded_detail(_detail), do: %{}

  defp class_atom(class) do
    {:ok, class} = AuthorityClass.cast(class)
    class
  end
end
