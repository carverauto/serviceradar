defmodule ServiceRadar.Notifications.Grouping do
  @moduledoc """
  Pure route-group timing and snapshot aggregation.

  A notification group has two timing rules:

    * `group_wait_seconds` delays only the first rung sent to a destination for
      a new group.
    * `group_interval_seconds` delays a later update to that same rung and
      destination until the prior grouped notification is old enough.

  The dispatcher owns persistence and locking. This module only computes the
  not-before instant and merges the alert snapshots that arrive while a grouped
  delivery is still pending.

  Group members are bounded so an operator-controlled dedupe template cannot
  turn one delivery row into an unbounded JSON document. The rendered
  `alert.message` / `alert.description` contains every retained member, so the
  built-in templates include siblings without requiring a looping template
  language.
  """

  @max_members 50
  @member_text_bytes 1_000

  @doc "Maximum distinct alert snapshots retained in one grouped delivery."
  @spec max_members() :: pos_integer()
  def max_members, do: @max_members

  @doc "Whether a route enables either grouping timing rule."
  @spec enabled?(map() | nil) :: boolean()
  def enabled?(route) when is_map(route) do
    seconds(field(route, :group_wait_seconds)) > 0 or
      seconds(field(route, :group_interval_seconds)) > 0
  end

  def enabled?(_route), do: false

  @doc "Computes the earliest instant a planned grouped delivery may run."
  @spec not_before(map()) :: DateTime.t()
  def not_before(%{due_at: %DateTime{} = due_at} = context) do
    route = Map.get(context, :route)
    last_sent_at = Map.get(context, :last_sent_at)

    candidate =
      cond do
        match?(%DateTime{}, last_sent_at) ->
          DateTime.add(last_sent_at, seconds(field(route, :group_interval_seconds)), :second)

        first_step?(context) ->
          DateTime.add(due_at, seconds(field(route, :group_wait_seconds)), :second)

        true ->
          due_at
      end

    latest(due_at, candidate)
  end

  @doc "Merges one incoming alert into a pending grouped delivery snapshot."
  @spec merge_snapshots(map(), map()) :: map()
  def merge_snapshots(existing, incoming) when is_map(existing) and is_map(incoming) do
    previous_members = members(existing)
    incoming_member = member(incoming)
    previous_size = integer(existing["group_size"], length(previous_members))

    {merged, new_member?} = upsert(previous_members, incoming_member)
    {retained, truncated?} = bound_members(merged)
    group_size = if new_member?, do: previous_size + 1, else: max(previous_size, length(merged))

    retained
    |> List.first(incoming_member)
    |> Map.merge(%{
      "grouped_alerts" => retained,
      "group_size" => group_size,
      "group_truncated" => truncated? or existing["group_truncated"] == true,
      "occurrence_count" => occurrence_count(retained),
      "last_seen_at" => last_seen_at(retained)
    })
    |> put_group_content(retained, group_size)
  end

  def merge_snapshots(_existing, incoming) when is_map(incoming), do: incoming

  @doc "Rebuilds a bounded aggregate from durable, per-member snapshots."
  @spec aggregate_snapshots([map()]) :: map()
  def aggregate_snapshots(snapshots) when is_list(snapshots) do
    snapshots
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn snapshot, aggregate ->
      merge_snapshots(aggregate, snapshot)
    end)
  end

  defp first_step?(context) do
    step_number = Map.get(context, :step_number)
    first_step_number = Map.get(context, :first_step_number)
    not is_nil(step_number) and step_number == first_step_number
  end

  defp members(%{"grouped_alerts" => members}) when is_list(members) and members != [] do
    Enum.filter(members, &is_map/1)
  end

  defp members(snapshot) when map_size(snapshot) == 0, do: []
  defp members(snapshot), do: [member(snapshot)]

  defp member(snapshot) do
    Map.drop(snapshot, [
      "grouped_alerts",
      "group_size",
      "group_truncated",
      "group_summary"
    ])
  end

  defp upsert(members, incoming) do
    incoming_id = incoming["id"]

    case Enum.find_index(members, &same_member?(&1, incoming, incoming_id)) do
      nil -> {members ++ [incoming], true}
      index -> {List.replace_at(members, index, incoming), false}
    end
  end

  defp same_member?(member, _incoming, incoming_id) when is_binary(incoming_id),
    do: member["id"] == incoming_id

  defp same_member?(member, incoming, _incoming_id), do: member == incoming

  defp bound_members(members) when length(members) <= @max_members, do: {members, false}

  defp bound_members([first | rest]) do
    {[first | Enum.take(rest, -(@max_members - 1))], true}
  end

  defp put_group_content(snapshot, _members, 1), do: snapshot

  defp put_group_content(snapshot, members, group_size) do
    title = text(snapshot["title"], "ServiceRadar alert")
    summary = Enum.map_join(members, "\n", &member_line/1)

    snapshot
    |> Map.put("title", "#{title} (+#{group_size - 1} grouped)")
    |> Map.put("message", summary)
    |> Map.put("description", summary)
    |> Map.put("group_summary", summary)
  end

  defp member_line(member) do
    severity = member |> Map.get("severity") |> text("unknown") |> String.upcase()
    title = text(member["title"], "ServiceRadar alert")
    detail = text(member["message"] || member["description"], "No further detail was reported.")

    "- [#{severity}] #{bounded(title)} - #{bounded(detail)}"
  end

  defp occurrence_count(members) do
    members
    |> Enum.map(&integer(&1["occurrence_count"], 1))
    |> Enum.sum()
  end

  defp last_seen_at(members) do
    members
    |> Enum.map(& &1["last_seen_at"])
    |> Enum.filter(&is_binary/1)
    |> Enum.max(fn -> nil end)
  end

  defp bounded(value), do: String.slice(value, 0, @member_text_bytes)

  defp text(value, _default) when is_binary(value) and value != "", do: value
  defp text(value, _default) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp text(_value, default), do: default

  defp integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp integer(_value, default), do: default

  defp seconds(value) when is_integer(value) and value > 0, do: value
  defp seconds(_value), do: 0

  defp latest(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.after?(right, left), do: right, else: left
  end

  defp field(record, key) when is_map(record), do: Map.get(record, key)
  defp field(_record, _key), do: nil
end
