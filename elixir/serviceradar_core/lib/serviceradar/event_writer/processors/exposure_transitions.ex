defmodule ServiceRadar.EventWriter.Processors.ExposureTransitions do
  @moduledoc """
  Consumes schema-v1 assessment after-images from the producer-owned
  `EXPOSURE_TRANSITIONS` stream. Both the conditional current-state load and
  append-only history must succeed before the batch is acknowledged.

  Ordinals are allocated by the assessment transaction. A missing device
  ordinal is counted and dropped. Known severity words keep their ranks. A
  null severity and any other binary severity store a null `severity_rank`,
  and the history payload keeps the original value. Non-binary severity and
  other malformed after-images fail the batch.
  Lifecycle markers fence complete fact after-images across replicas. Snapshot
  generation remains a separate recovery protocol.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.EventWriter.ExposureLifecycle

  @max_bigint 9_223_372_036_854_775_807
  @required ~w(device_ord cve_ord pkg_ord pkgver_ord transition_seq transition_xid
               state source_scope severity cvss_score kev exploit_available fix_available
               first_exposed_at resolved_at changed_at)
  @ranks %{"none" => 0, "unknown" => 0, "low" => 1, "medium" => 2, "high" => 3, "critical" => 4}

  @impl true
  def table_name, do: "exposure_facts"

  @impl true
  def process_batch(messages) do
    if Destination.enabled?() do
      ExposureDelivery.run(messages, &ingest_batch/2)
    else
      {:error, :starrocks_required}
    end
  end

  @doc "Applies one journaled batch under its delivery owner's lock checks."
  def ingest_batch(messages, locked) do
    if Destination.enabled?() do
      with {:ok, events} <- decode(messages),
           {:ok, transitions} <- ExposureLifecycle.prepare(events, locked),
           {:ok, _} <-
             ExposureDelivery.persist(:exposure_facts, latest_facts(transitions), locked),
           {:ok, _} <-
             ExposureDelivery.persist(
               :exposure_transitions_log,
               Enum.map(transitions, & &1.history),
               locked
             ) do
        {:ok, length(transitions)}
      end
    else
      {:retry, :starrocks_required}
    end
  end

  defp decode(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, rows} ->
      case decode_message(message) do
        {:ok, row} ->
          {:cont, {:ok, [row | rows]}}

        :missing_device_ordinal ->
          :telemetry.execute([:serviceradar, :exposure, :transition, :dropped], %{count: 1}, %{
            reason: :missing_device_ordinal
          })

          {:cont, {:ok, rows}}

        :error ->
          {:halt, {:retry, :invalid_exposure_transition}}
      end
    end)
  end

  defp decode_message(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"schema_version" => 1, "device_ord" => nil}} ->
        :missing_device_ordinal

      {:ok, %{"schema_version" => 1, "event_type" => event} = payload}
      when event in ["device_retired", "device_restored"] ->
        lifecycle(payload)

      {:ok, %{"schema_version" => 1} = payload} ->
        after_image(payload)

      _ ->
        :error
    end
  end

  defp decode_message(_), do: :error

  defp after_image(payload) do
    payload = Map.put_new(payload, "device_lifecycle_seq", 0)

    with true <- Enum.all?(@required, &Map.has_key?(payload, &1)),
         true <- valid_ordinals?(payload),
         true <- valid_attributes?(payload),
         {:ok, updated} <- datetime(payload["changed_at"]),
         {:ok, first} <- nullable_datetime(payload["first_exposed_at"]),
         {:ok, resolved} <- nullable_datetime(payload["resolved_at"]),
         {:ok, state} <- Map.fetch(%{"active" => 1, "resolved" => 0}, payload["state"]),
         {:ok, severity} <- severity_rank(payload["severity"]) do
      fact =
        payload
        |> Map.take(
          ~w(device_ord device_lifecycle_seq cve_ord pkg_ord pkgver_ord transition_seq transition_xid source_scope cvss_score kev exploit_available fix_available)
        )
        |> Map.merge(%{
          "state" => state,
          "severity_rank" => severity,
          "updated_at" => updated,
          "first_exposed_at" => first,
          "resolved_at" => resolved
        })

      history =
        fact
        |> Map.take(
          ~w(device_ord cve_ord pkg_ord pkgver_ord state transition_seq transition_xid first_exposed_at resolved_at)
        )
        |> Map.merge(%{"changed_at" => updated, "payload" => payload})

      {:ok, %{kind: :fact, device_ord: payload["device_ord"], fact: fact, history: history}}
    else
      _ -> :error
    end
  end

  defp lifecycle(payload) do
    retired? = payload["event_type"] == "device_retired"
    seq = payload["transition_seq"]
    retired_seq = payload["retired_seq"]

    with true <- ordinal?(payload["device_ord"], 4_294_967_295),
         true <- ordinal?(seq, @max_bigint),
         true <- payload["device_lifecycle_seq"] == seq,
         true <- ordinal?(payload["transition_xid"], @max_bigint),
         true <- ordinal?(retired_seq, @max_bigint),
         true <- ordinal?(payload["retired_xid"], @max_bigint),
         true <- if(retired?, do: retired_seq == seq, else: retired_seq < seq),
         true <- payload["state"] == if(retired?, do: "retired", else: "live"),
         {:ok, updated} <- datetime(payload["changed_at"]),
         {:ok, retired_at} <- datetime(payload["retired_at"]) do
      row =
        payload
        |> Map.take(~w(device_ord transition_seq transition_xid retired_seq retired_xid))
        |> Map.merge(%{
          "state" => if(retired?, do: 2, else: 1),
          "updated_at" => updated,
          "retired_at" => retired_at
        })

      {:ok, %{kind: :lifecycle, device_ord: payload["device_ord"], row: row}}
    else
      _ -> :error
    end
  end

  defp valid_ordinals?(payload) do
    is_integer(payload["device_lifecycle_seq"]) and payload["device_lifecycle_seq"] >= 0 and
      is_integer(payload["transition_seq"]) and
      payload["device_lifecycle_seq"] < payload["transition_seq"] and
      ordinal?(payload["device_ord"], 4_294_967_295) and
      Enum.all?(
        ~w(cve_ord pkg_ord pkgver_ord transition_seq transition_xid),
        &ordinal?(payload[&1], @max_bigint)
      )
  end

  defp ordinal?(value, maximum), do: is_integer(value) and value > 0 and value <= maximum

  defp valid_attributes?(payload) do
    scope = payload["source_scope"]
    score = payload["cvss_score"]

    (is_nil(scope) or (is_binary(scope) and byte_size(scope) <= 32)) and
      (is_nil(score) or (is_number(score) and score >= 0 and score <= 10)) and
      Enum.all?(~w(kev exploit_available fix_available), &(payload[&1] in [nil, true, false]))
  end

  defp severity_rank(nil), do: {:ok, nil}

  defp severity_rank(value) when is_binary(value) do
    {:ok, Map.get(@ranks, String.downcase(value))}
  end

  defp severity_rank(_), do: :error

  defp nullable_datetime(nil), do: {:ok, nil}
  defp nullable_datetime(value), do: datetime(value)

  defp datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} ->
        {:ok, datetime |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()}

      _ ->
        :error
    end
  end

  defp datetime(_), do: :error

  # A load can contain several deliveries for one key. Select the newest whole
  # after-image before loading, independently of delivery order within a batch.
  # StarRocks' merge condition handles ordering between batches.
  defp latest_facts(transitions) do
    transitions
    |> Enum.map(& &1.fact)
    |> Enum.group_by(&{&1["device_ord"], &1["cve_ord"], &1["pkg_ord"]})
    |> Enum.map(fn {_key, rows} -> Enum.max_by(rows, & &1["transition_seq"]) end)
  end
end
