defmodule ServiceRadar.EventWriter.ExposureLifecycle do
  @moduledoc "Warehouse lifecycle fencing, called only under ExposureDelivery ownership."
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.EventWriter.ExposureDelivery

  @page_size 500
  @pages_per_batch 20

  def prepare(events, locked) do
    ordinals = events |> Enum.map(& &1.device_ord) |> Enum.uniq() |> Enum.sort()

    with {:ok, current} <- read_states(ordinals),
         {:ok, current} <- apply_markers(events, current, locked),
         :ok <- retire_facts(current, locked) do
      admit(events, current)
    end
  end

  defp read_states([]), do: {:ok, %{}}

  defp read_states(ordinals) do
    with {:ok, rows} <-
           rows(
             "SELECT * FROM #{Env.table("exposure_retired_ordinals")} WHERE device_ord IN (#{Enum.join(ordinals, ",")})"
           ) do
      {:ok, Map.new(rows, &{&1["device_ord"], &1})}
    end
  end

  defp apply_markers(events, current, locked) do
    events
    |> Enum.filter(&(&1.kind == :lifecycle))
    |> Enum.group_by(& &1.device_ord)
    |> Enum.reduce_while({:ok, current}, fn {ordinal, markers}, {:ok, states} ->
      marker = Enum.max_by(markers, & &1.row["transition_seq"])
      previous = Map.get(states, ordinal, %{"transition_seq" => 0})

      if marker.row["transition_seq"] > previous["transition_seq"] do
        case ExposureDelivery.persist(:exposure_retired_ordinals, [marker.row], locked) do
          {:ok, _} -> {:cont, {:ok, Map.put(states, ordinal, marker.row)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, states}}
      end
    end)
  end

  defp retire_facts(states, locked) do
    Enum.reduce_while(states, :ok, fn {_ordinal, state}, :ok ->
      case retire_page(state, locked, @pages_per_batch) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retire_page(%{"retired_seq" => 0}, _locked, _pages), do: :ok
  defp retire_page(_state, _locked, 0), do: {:error, :exposure_retirement_incomplete}

  defp retire_page(state, locked, pages) do
    columns = Enum.join(Rows.exposure_fact_columns(), ",")

    sql = """
    SELECT #{columns} FROM #{Env.table("exposure_facts")}
    WHERE device_ord = #{state["device_ord"]} AND transition_seq < #{state["retired_seq"]}
    ORDER BY cve_ord, pkg_ord LIMIT #{@page_size}
    """

    with {:ok, facts} <- rows(sql) do
      if facts == [] do
        :ok
      else
        retired =
          Enum.map(
            facts,
            &Map.merge(&1, %{
              "state" => 2,
              "transition_seq" => state["retired_seq"],
              "transition_xid" => state["retired_xid"],
              "resolved_at" => state["retired_at"],
              "updated_at" => state["retired_at"]
            })
          )

        # History must settle first: after the fact load commits, a recovered
        # sweep no longer selects these keys and cannot reconstruct a lost append.
        with {:ok, _} <-
               ExposureDelivery.persist(
                 :exposure_transitions_log,
                 retirement_history(retired),
                 locked
               ),
             {:ok, _} <- ExposureDelivery.persist(:exposure_facts, retired, locked) do
          retire_page(state, locked, pages - 1)
        end
      end
    end
  end

  defp retirement_history(facts) do
    Enum.map(facts, fn fact ->
      fact
      |> Map.take(
        ~w(device_ord cve_ord pkg_ord pkgver_ord state transition_seq transition_xid first_exposed_at resolved_at)
      )
      |> Map.merge(%{
        "changed_at" => fact["updated_at"],
        "payload" => %{"event_type" => "device_retired", "after_image" => fact}
      })
    end)
  end

  defp admit(events, states) do
    Enum.reduce_while(events, {:ok, []}, fn
      %{kind: :lifecycle}, acc ->
        {:cont, acc}

      event, {:ok, accepted} ->
        current = Map.get(states, event.device_ord, %{"state" => 1, "transition_seq" => 0})
        lifecycle = event.fact["device_lifecycle_seq"]

        cond do
          lifecycle > current["transition_seq"] ->
            {:halt, {:retry, :exposure_lifecycle_pending}}

          lifecycle < current["transition_seq"] or current["state"] == 2 ->
            :telemetry.execute([:serviceradar, :exposure, :transition, :dropped], %{count: 1}, %{
              reason: :retired_lifecycle
            })

            {:cont, {:ok, accepted}}

          true ->
            {:cont, {:ok, [event | accepted]}}
        end
    end)
  end

  defp rows(sql) do
    with {:ok, %{columns: columns, rows: values}} <- Query.execute(sql) do
      {:ok,
       Enum.map(values, fn row ->
         columns |> Enum.zip(row) |> Map.new(fn {key, value} -> {key, scalar(value)} end)
       end)}
    end
  end

  defp scalar(%NaiveDateTime{} = value), do: NaiveDateTime.to_string(value)
  defp scalar(%Decimal{} = value), do: Decimal.to_float(value)
  defp scalar(value), do: value
end
