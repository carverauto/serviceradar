defmodule ServiceRadar.EventWriter.ExposureSnapshotWarehouse do
  @moduledoc "Snapshot comparison and immutable warehouse effects, under the shared lane lock."
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.EventWriter.ExposureDelivery
  alias ServiceRadar.EventWriter.ExposureLifecycle
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.EventWriter.Processors.ExposureDimensions
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo

  def plan(generation, %{"phase" => "dimensions"} = envelope) do
    with {:ok, decoded} <- ExposureDimensions.decode(messages(envelope)),
         {:ok, stored} <- read(envelope["lane"], Enum.map(decoded, &elem(&1, 1))) do
      expected = if envelope["lane"] == "cve", do: :cve, else: :package

      if Enum.all?(decoded, fn {kind, _, _} -> kind == expected end) do
        {writes, repairs} =
          Enum.reduce(decoded, {[], []}, fn {_, ordinal, row}, {writes, repairs} ->
            current = stored[ordinal]

            if current && current["transition_seq"] == row["transition_seq"] &&
                 row_digest(envelope["lane"], current) != row_digest(envelope["lane"], row) do
              {writes,
               [
                 %{
                   "kind" => envelope["lane"],
                   "key" => ordinal,
                   "observed" => current["transition_seq"]
                 }
                 | repairs
               ]}
            else
              {[row | writes], repairs}
            end
          end)

        {:ok,
         %{
           "phase" => "dimensions",
           "rows" => writes,
           "repairs" => repairs,
           "generation" => generation["id"],
           "load_limits" => snapshot_limits()
         }}
      else
        {:error, :exposure_snapshot_lane_conflict}
      end
    end
  end

  def plan(generation, %{"phase" => "lifecycle"} = envelope) do
    with :ok <- validate_devices(generation, envelope),
         {:ok, events} <- ExposureTransitions.decode(messages(envelope)),
         true <- Enum.all?(events, &(&1.kind == :lifecycle)),
         {:ok, stored} <- read("lifecycle", Enum.map(events, & &1.device_ord)) do
      visible = visibility(Map.values(stored), generation["snapshot"])

      repairs =
        Enum.flat_map(events, fn event ->
          current = stored[event.device_ord]

          if current &&
               ((current["transition_seq"] == event.row["transition_seq"] &&
                   row_digest("lifecycle", current) != row_digest("lifecycle", event.row)) or
                  (current["transition_seq"] > event.row["transition_seq"] and
                     visible[current["transition_xid"]])) do
            [
              %{
                "kind" => "lifecycle",
                "key" => event.device_ord,
                "observed" => current["transition_seq"]
              }
            ]
          else
            []
          end
        end)

      repair_keys = MapSet.new(repairs, & &1["key"])

      {:ok,
       %{
         "phase" => "lifecycle",
         "records" =>
           Enum.reject(envelope["records"], &MapSet.member?(repair_keys, &1["device_ord"])),
         "repairs" => repairs,
         "generation" => generation["id"],
         "load_limits" => snapshot_limits()
       }}
    else
      false -> {:error, :exposure_snapshot_phase_conflict}
      error -> error
    end
  end

  def plan(generation, %{"phase" => "facts"} = envelope) do
    with :ok <- validate_devices(generation, envelope),
         {:ok, events} <- ExposureTransitions.decode(messages(envelope)),
         true <- Enum.all?(events, &(&1.kind == :fact)),
         {:ok, admitted} <- ExposureLifecycle.admit_current(events),
         {:ok, current} <- facts(Enum.map(admitted, &key(&1.fact))) do
      visible = visibility(Map.values(current), generation["snapshot"])
      publications = Map.new(envelope["records"], &{key(&1), &1})

      {writes, repairs, post_snapshot} =
        Enum.reduce(admitted, {[], [], 0}, fn event, {writes, repairs, post} ->
          fact = event.fact
          stored = current[key(fact)]

          cond do
            is_nil(stored) or stored["transition_seq"] < fact["transition_seq"] ->
              {[Map.put(fact, "snapshot_generation", generation["id"]) | writes], repairs, post}

            stored["transition_seq"] == fact["transition_seq"] and identical?(fact, stored) ->
              {[Map.put(fact, "snapshot_generation", generation["id"]) | writes], repairs, post}

            stored["transition_seq"] > fact["transition_seq"] and
                not visible[stored["transition_xid"]] ->
              {writes, repairs, post + 1}

            true ->
              publication = publications[key(fact)]

              repair = %{
                "key" => key(fact),
                "observed" => stored["transition_seq"],
                "source" => Enum.map(~w(device_uid package_identity_key cve_id), &publication[&1])
              }

              {writes, [repair | repairs], post}
          end
        end)

      {:ok,
       %{
         "phase" => "facts",
         "rows" => writes,
         "repairs" => repairs,
         "post_snapshot" => post_snapshot,
         "retired" => length(events) - length(admitted),
         "generation" => generation["id"],
         "load_limits" => snapshot_limits()
       }}
    else
      false -> {:error, :exposure_snapshot_phase_conflict}
      error -> error
    end
  end

  def apply_plan(%{"phase" => "facts", "rows" => rows} = plan, identity, locked) do
    with {:ok, _} <-
           ExposureDelivery.persist_snapshot(
             :exposure_snapshot_facts,
             rows,
             locked,
             identity,
             load_limits(plan)
           ),
         do: :ok
  end

  def apply_plan(%{"phase" => "dimensions", "rows" => rows} = plan, identity, locked) do
    [_generation, lane, _page] = identity
    dataset = if lane == "cve", do: :exposure_cve_dim, else: :exposure_package_dim

    with {:ok, _} <-
           ExposureDelivery.persist_snapshot(dataset, rows, locked, identity, load_limits(plan)),
         do: :ok
  end

  def apply_plan(%{"phase" => "lifecycle", "records" => records} = plan, identity, locked) do
    with {:ok, events} <-
           ExposureTransitions.decode(Enum.map(records, &%{data: Jason.encode!(&1)})),
         {:ok, _} <-
           ExposureLifecycle.prepare(events, locked,
             snapshot: identity,
             snapshot_limits: load_limits(plan),
             history: false
           ),
         do: :ok
  end

  # Keep physical boundaries with the immutable plan. A retry must settle the
  # original chunks even after a replica's runtime batch settings change.
  defp snapshot_limits do
    limits = Destination.stream_load_limits()

    %{
      "max_rows" => min(limits[:max_rows], 500),
      "max_bytes" => min(limits[:max_bytes], 512 * 1024)
    }
  end

  defp load_limits(%{"load_limits" => limits}),
    do: [max_rows: limits["max_rows"], max_bytes: limits["max_bytes"], max_in_flight: 1]

  def read("fact", keys), do: facts(keys)
  def read(_kind, []), do: {:ok, %{}}

  def read(kind, keys) when kind in ["cve", "package", "lifecycle"] do
    {table, key} =
      case kind do
        "cve" -> {"exposure_cve_dim", "cve_ord"}
        "package" -> {"exposure_package_dim", "pkgver_ord"}
        "lifecycle" -> {"exposure_retired_ordinals", "device_ord"}
      end

    with {:ok, rows} <-
           rows("SELECT * FROM #{Env.table(table)} WHERE #{key} IN (#{Enum.join(keys, ",")})"),
         do: {:ok, Map.new(rows, &{&1[key], &1})}
  end

  def facts([]), do: {:ok, %{}}

  def facts(keys) do
    tuples = Enum.map_join(keys, ",", fn key -> "(" <> Enum.join(key, ",") <> ")" end)

    with {:ok, rows} <-
           rows(
             "SELECT * FROM #{Env.table("exposure_facts")} WHERE (device_ord,cve_ord,pkg_ord) IN (#{tuples})"
           ) do
      {:ok, Map.new(rows, &{key(&1), &1})}
    end
  end

  def scan(scope, [device, cve, package]) do
    scope_sql = if scope, do: "AND device_ord = #{scope}", else: ""

    rows("""
    SELECT * FROM #{Env.table("exposure_facts")}
    WHERE (device_ord,cve_ord,pkg_ord) > (#{device},#{cve},#{package}) #{scope_sql}
    ORDER BY device_ord,cve_ord,pkg_ord LIMIT 500
    """)
  end

  def visibility(rows, snapshot) do
    xids = rows |> Enum.map(&to_string(&1["transition_xid"])) |> Enum.uniq()

    Map.new(
      Repo.query!(
        """
        SELECT xid, pg_visible_in_snapshot(xid::xid8, $2::text::pg_snapshot)
        FROM unnest($1::text[]) AS xid
        """,
        [xids, snapshot]
      ).rows,
      fn [xid, visible] -> {String.to_integer(xid), visible} end
    )
  end

  def key(row), do: Enum.map(~w(device_ord cve_ord pkg_ord), &row[&1])

  def fact_digest(row), do: row_digest("fact", row)

  def row_digest(kind, row) do
    columns =
      case kind do
        "fact" ->
          Rows.exposure_fact_columns()

        "cve" ->
          ~w(cve_ord cve_id epss_score transition_seq updated_at)

        "package" ->
          ~w(pkgver_ord pkg_ord package_identity_key package_name installed_version transition_seq updated_at)

        "lifecycle" ->
          ~w(device_ord state transition_seq transition_xid retired_seq retired_xid retired_at updated_at)
      end

    row
    |> Map.take(columns)
    |> Map.new(fn {key, value} -> {key, normalize(key, value)} end)
    |> Envelope.canonical()
    |> Envelope.digest()
  end

  defp validate_devices(generation, envelope) do
    valid =
      Enum.all?(envelope["records"], fn record ->
        uid = record["device_uid"]

        is_binary(uid) and
          "device-" <> List.last(String.split(ExposureTransitionRelay.subject(uid), ".")) ==
            envelope["lane"] and
          (generation["scope"] == nil or record["device_ord"] == generation["scope"])
      end)

    if valid, do: :ok, else: {:error, :exposure_snapshot_lane_conflict}
  end

  defp identical?(left, right) do
    Enum.all?(Rows.exposure_fact_columns(), fn column ->
      normalize(column, left[column]) == normalize(column, right[column])
    end)
  end

  defp normalize(column, value)
       when column in ~w(kev exploit_available fix_available) and value in [0, 1], do: value == 1

  defp normalize(column, value) when column in ~w(cvss_score epss_score) and is_number(value),
    do: value * 1.0

  defp normalize(_column, value), do: value

  defp messages(envelope), do: Enum.map(envelope["records"], &%{data: Jason.encode!(&1)})

  def rows(sql) do
    with {:ok, %{columns: columns, rows: values}} <- Query.execute(sql) do
      {:ok,
       Enum.map(values, fn row ->
         columns |> Enum.zip(row) |> Map.new(fn {key, value} -> {key, scalar(value)} end)
       end)}
    end
  end

  defp scalar(%NaiveDateTime{} = value),
    do: value |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

  defp scalar(%Decimal{} = value), do: Decimal.to_float(value)
  defp scalar(value), do: value
end
