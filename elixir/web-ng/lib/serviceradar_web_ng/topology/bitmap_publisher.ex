defmodule ServiceRadarWebNG.Topology.BitmapPublisher do
  @moduledoc """
  Publishes scalar inventory and complete current address replacements together.

  A repeatable-read transaction streams at most 500 address associations into
  the native stage per fetch. Ash owns the scalar projection. Fixed SQL cursors
  flatten typed address arrays without loading whole interface rows into BEAM.
  Invalid numeric addresses are ignored; source/native capacity failures disable
  the IP capability explicitly. Historical uncorroborated identifiers are excluded.
  A native memory admission failure returns `{:capacity, result}` with the
  unpublished read so its owner can defer those ordinals and keep reconciling.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Topology.BitmapAddress
  alias ServiceRadarWebNG.Topology.Native

  @timeout 8_000
  @batch_size 500
  @array_limit 4_096
  @capacity ["native_memory_budget", :native_memory_budget]

  @addresses """
  SELECT address.ordinal,
         left(split_part(split_part(btrim(address.value), '/', 1), '%', 1), 257),
         address.capped
  FROM (
    SELECT f.ordinal, d.ip AS value, false AS capped
    FROM platform.device_fleet_ordinals f
    JOIN platform.ocsf_devices d ON d.uid = f.uid
    WHERE f.ordinal = ANY($1::bigint[])
    UNION ALL
    SELECT f.ordinal, a.alias_value, false
    FROM platform.device_fleet_ordinals f
    JOIN platform.device_alias_states a ON a.device_id = f.uid
    WHERE f.ordinal = ANY($1::bigint[])
      AND a.alias_type IN ('ip', 'interface_ip')
      AND a.state IN ('detected', 'confirmed', 'updated')
    UNION ALL
    SELECT f.ordinal, value.ip, cardinality(i.ip_addresses) > #{@array_limit}
    FROM platform.device_fleet_ordinals f
    JOIN platform.discovered_interfaces i ON i.device_id = f.uid
    CROSS JOIN LATERAL unnest(
      CASE WHEN cardinality(i.ip_addresses) > #{@array_limit}
        THEN ARRAY[NULL::text] ELSE i.ip_addresses END
    ) value(ip)
    WHERE f.ordinal = ANY($1::bigint[])
    UNION ALL
    SELECT f.ordinal, value.ip, cardinality(i.ip_addresses) > #{@array_limit}
    FROM platform.device_fleet_ordinals f
    JOIN platform.virtualization_network_interfaces i ON i.device_uid = f.uid
    CROSS JOIN LATERAL unnest(
      CASE WHEN cardinality(i.ip_addresses) > #{@array_limit}
        THEN ARRAY[NULL::text]
        ELSE ARRAY[i.address, i.cidr] || coalesce(i.ip_addresses, ARRAY[]::text[]) END
    ) value(ip)
    WHERE f.ordinal = ANY($1::bigint[]) AND i.exists IS DISTINCT FROM false
  ) address
  """

  def publish(current, read, ready, sequence) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    with {:ok, {stage, result}} <-
           Repo.transaction(fn -> stage(current, read, ready, sequence, deadline) end,
             timeout: @timeout,
             deadline: deadline
           ) do
      try do
        case Native.bitmap_index_finish_publish(current.device, stage) do
          {:ok, _} -> {:ok, result}
          {:error, reason} -> {:error, capacity(reason, result)}
        end
      after
        Native.bitmap_publish_abort(stage)
      end
    end
  end

  defp stage(current, read, ready, sequence, deadline) do
    SQL.query!(Repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [], timeout: remaining!(deadline))
    statement_deadline(deadline)

    case read.() do
      {:ok, result} ->
        with {:ok, status} <- Native.bitmap_index_status(current.device),
             {:ok, stage} <-
               Native.bitmap_index_begin_publish(
                 current.device,
                 status.revision,
                 <<sequence::unsigned-64>>,
                 result.rows,
                 ready.(result)
               ) do
          populate(stage, result, deadline)
        else
          {:error, reason} -> Repo.rollback(capacity(reason, result))
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp populate(stage, result, deadline) do
    case Native.bitmap_publish_addresses(stage, [], []) do
      {:ok, %{ip_available: false}} -> {stage, result}
      {:ok, %{ip_available: true}} -> populate_addresses(stage, result, deadline)
      {:error, reason} -> abort(stage, capacity(reason, result))
    end
  rescue
    exception ->
      Native.bitmap_publish_abort(stage)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      Native.bitmap_publish_abort(stage)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp populate_addresses(stage, result, deadline) do
    ordinals = for {ordinal, true, _} <- result.rows, do: ordinal

    case stream(stage, ordinals, deadline) do
      :ok ->
        completed = Enum.map(result.rows, &elem(&1, 0))

        case Native.bitmap_publish_addresses(stage, [], completed) do
          {:ok, _} -> {stage, result}
          {:error, reason} -> abort(stage, capacity(reason, result))
        end

      :unavailable ->
        {stage, result}

      {:error, reason} ->
        abort(stage, capacity(reason, result))
    end
  end

  defp stream(_stage, [], _deadline), do: :ok

  defp stream(stage, ordinals, deadline) do
    statement_deadline(deadline)

    Repo
    |> SQL.stream(@addresses, [ordinals],
      max_rows: @batch_size,
      timeout: remaining!(deadline),
      deadline: deadline
    )
    |> Enum.reduce_while(:ok, fn %{rows: rows}, :ok ->
      remaining!(deadline)

      case add_addresses(stage, rows) do
        :ok -> {:cont, :ok}
        stopped -> {:halt, stopped}
      end
    end)
  end

  defp add_addresses(stage, rows) do
    if Enum.any?(rows, fn [_, _, capped] -> capped == true end) do
      case Native.bitmap_publish_ip_unavailable(stage) do
        {:ok, _} -> :unavailable
        error -> error
      end
    else
      addresses =
        for [ordinal, value, _] <- rows,
            {:ok, packed} <- [BitmapAddress.source(value)],
            do: {ordinal, packed}

      case Native.bitmap_publish_addresses(stage, addresses, []) do
        {:ok, %{ip_available: true}} -> :ok
        {:ok, %{ip_available: false}} -> :unavailable
        error -> error
      end
    end
  end

  defp capacity(reason, result) when reason in @capacity, do: {:capacity, result}
  defp capacity(reason, _result), do: reason

  defp abort(stage, reason) do
    Native.bitmap_publish_abort(stage)
    Repo.rollback(reason)
  end

  defp statement_deadline(deadline) do
    timeout = remaining!(deadline)
    SQL.query!(Repo, "SELECT set_config('statement_timeout', $1, true)", [Integer.to_string(timeout)], timeout: timeout)
  end

  defp remaining!(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> Repo.rollback(:source_timeout)
    end
  end
end
