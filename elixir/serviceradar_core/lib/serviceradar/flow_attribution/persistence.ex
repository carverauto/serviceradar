defmodule ServiceRadar.FlowAttribution.Persistence do
  @moduledoc false

  alias ServiceRadar.Backoff

  @schema "platform"
  @table "flow_process_attribution_current"
  @workload_identity_table "workload_identity_current"
  @deadlock_retries 3
  @deadlock_backoff_opts [base_ms: 10, max_ms: 80, factor: 2.0, jitter: 0.2]

  @upsert_sql """
  WITH input_rows AS (
    SELECT
      r.observed_at::timestamptz AS observed_at,
      r.partition,
      r.attribution_key,
      r.agent_id,
      r.proto,
      r.local_ip,
      r.local_port,
      r.remote_ip,
      r.remote_port,
      r.pid,
      r.comm,
      r.cmdline,
      r.uid,
      r.container_id,
      r.workload_identity
    FROM jsonb_to_recordset(($1::text)::jsonb) AS r(
      observed_at text,
      partition text,
      attribution_key text,
      agent_id text,
      proto integer,
      local_ip text,
      local_port integer,
      remote_ip text,
      remote_port integer,
      pid integer,
      comm text,
      cmdline text,
      uid integer,
      container_id text,
      workload_identity jsonb
    )
  ),
  deduped AS (
    SELECT DISTINCT ON (partition, attribution_key)
      observed_at,
      partition,
      attribution_key,
      agent_id,
      proto,
      local_ip,
      local_port,
      remote_ip,
      remote_port,
      pid,
      comm,
      cmdline,
      uid,
      container_id,
      workload_identity
    FROM input_rows
    ORDER BY
      partition,
      attribution_key,
      -- Prefer container-scoped owners over host-only dual emits for the same socket.
      container_id IS NULL,
      observed_at DESC,
      cmdline IS NULL,
      uid IS NULL,
      workload_identity IS NULL
  )
  INSERT INTO #{@schema}.#{@table} (
    observed_at,
    inserted_at,
    updated_at,
    partition,
    attribution_key,
    agent_id,
    proto,
    local_ip,
    local_port,
    remote_ip,
    remote_port,
    pid,
    comm,
    cmdline,
    uid,
    container_id,
    workload_identity
  )
  SELECT
    r.observed_at,
    now(),
    now(),
    r.partition,
    r.attribution_key,
    r.agent_id,
    r.proto,
    r.local_ip,
    r.local_port,
    r.remote_ip,
    r.remote_port,
    r.pid,
    r.comm,
    r.cmdline,
    r.uid,
    r.container_id,
    NULLIF(
      COALESCE(workload.identity, '{}'::jsonb) || COALESCE(r.workload_identity, '{}'::jsonb),
      '{}'::jsonb
    ) AS workload_identity
  FROM deduped AS r
  LEFT JOIN LATERAL (
    SELECT wi.identity
    FROM #{@schema}.#{@workload_identity_table} AS wi
    WHERE wi.partition = r.partition
      AND wi.agent_id = r.agent_id
      AND wi.container_id = r.container_id
    ORDER BY wi.observed_at DESC
    LIMIT 1
  ) AS workload ON r.container_id IS NOT NULL
  ORDER BY r.partition, r.attribution_key
  ON CONFLICT (partition, attribution_key) DO UPDATE SET
    observed_at = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN EXCLUDED.observed_at
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN #{@table}.observed_at
      ELSE GREATEST(#{@table}.observed_at, EXCLUDED.observed_at)
    END,
    updated_at = now(),
    pid = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN EXCLUDED.pid
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN #{@table}.pid
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at
        THEN COALESCE(EXCLUDED.pid, #{@table}.pid)
      ELSE COALESCE(#{@table}.pid, EXCLUDED.pid)
    END,
    comm = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN EXCLUDED.comm
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN #{@table}.comm
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at
        THEN COALESCE(EXCLUDED.comm, #{@table}.comm)
      ELSE COALESCE(#{@table}.comm, EXCLUDED.comm)
    END,
    cmdline = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN COALESCE(EXCLUDED.cmdline, #{@table}.cmdline)
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN COALESCE(#{@table}.cmdline, EXCLUDED.cmdline)
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at
        THEN COALESCE(EXCLUDED.cmdline, #{@table}.cmdline)
      ELSE COALESCE(#{@table}.cmdline, EXCLUDED.cmdline)
    END,
    uid = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN COALESCE(EXCLUDED.uid, #{@table}.uid)
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN COALESCE(#{@table}.uid, EXCLUDED.uid)
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at
        THEN COALESCE(EXCLUDED.uid, #{@table}.uid)
      ELSE COALESCE(#{@table}.uid, EXCLUDED.uid)
    END,
    container_id = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL
        THEN EXCLUDED.container_id
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL
        THEN #{@table}.container_id
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at
        THEN COALESCE(EXCLUDED.container_id, #{@table}.container_id)
      ELSE COALESCE(#{@table}.container_id, EXCLUDED.container_id)
    END,
    workload_identity = CASE
      WHEN EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL THEN
        NULLIF(
          COALESCE(#{@table}.workload_identity, '{}'::jsonb) || COALESCE(EXCLUDED.workload_identity, '{}'::jsonb),
          '{}'::jsonb
        )
      WHEN #{@table}.container_id IS NOT NULL AND EXCLUDED.container_id IS NULL THEN
        #{@table}.workload_identity
      WHEN EXCLUDED.observed_at >= #{@table}.observed_at THEN
        NULLIF(
          COALESCE(#{@table}.workload_identity, '{}'::jsonb) || COALESCE(EXCLUDED.workload_identity, '{}'::jsonb),
          '{}'::jsonb
        )
      WHEN #{@table}.workload_identity IS NULL THEN EXCLUDED.workload_identity
      ELSE #{@table}.workload_identity
    END
  WHERE
    -- Always accept a container-scoped owner over a host-only dual emit.
    (EXCLUDED.container_id IS NOT NULL AND #{@table}.container_id IS NULL)
     OR (
          EXCLUDED.container_id IS NOT NULL OR #{@table}.container_id IS NULL
        )
        AND (
          EXCLUDED.observed_at > #{@table}.observed_at
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND EXCLUDED.cmdline IS NOT NULL
               AND #{@table}.cmdline IS DISTINCT FROM EXCLUDED.cmdline
             )
          OR (#{@table}.cmdline IS NULL AND EXCLUDED.cmdline IS NOT NULL)
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND EXCLUDED.uid IS NOT NULL
               AND #{@table}.uid IS DISTINCT FROM EXCLUDED.uid
             )
          OR (#{@table}.uid IS NULL AND EXCLUDED.uid IS NOT NULL)
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND EXCLUDED.container_id IS NOT NULL
               AND #{@table}.container_id IS DISTINCT FROM EXCLUDED.container_id
             )
          OR (#{@table}.container_id IS NULL AND EXCLUDED.container_id IS NOT NULL)
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND EXCLUDED.pid IS NOT NULL
               AND #{@table}.pid IS DISTINCT FROM EXCLUDED.pid
             )
          OR (#{@table}.pid IS NULL AND EXCLUDED.pid IS NOT NULL)
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND EXCLUDED.comm IS NOT NULL
               AND #{@table}.comm IS DISTINCT FROM EXCLUDED.comm
             )
          OR (#{@table}.comm IS NULL AND EXCLUDED.comm IS NOT NULL)
          OR (
               EXCLUDED.observed_at >= #{@table}.observed_at
               AND NULLIF(
               COALESCE(#{@table}.workload_identity, '{}'::jsonb) || COALESCE(EXCLUDED.workload_identity, '{}'::jsonb),
               '{}'::jsonb
             ) IS DISTINCT FROM #{@table}.workload_identity
             )
          OR (#{@table}.workload_identity IS NULL AND EXCLUDED.workload_identity IS NOT NULL)
        )
  """

  @spec insert_current_rows([map()], keyword()) ::
          {:ok, Postgrex.Result.t()} | {:error, term()}
  def insert_current_rows(rows, opts \\ []) do
    rows =
      rows
      |> prepare_current_rows()
      |> Enum.map(fn row ->
        Map.update!(row, :observed_at, &DateTime.to_iso8601/1)
      end)

    query = Keyword.get(opts, :query, &ServiceRadar.Repo.query/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    retries = Keyword.get(opts, :deadlock_retries, @deadlock_retries)

    execute_with_deadlock_retry(
      Jason.encode!(rows),
      query,
      sleep,
      retries,
      Backoff.new(@deadlock_backoff_opts)
    )
  end

  @doc false
  @spec prepare_current_rows([map()]) :: [map()]
  def prepare_current_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      key = {Map.fetch!(row, :partition), Map.fetch!(row, :attribution_key)}

      Map.update(acc, key, row, fn current -> prefer_socket_owner(current, row) end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{Map.fetch!(&1, :partition), Map.fetch!(&1, :attribution_key)})
  end

  # Prefer container-scoped identity over host-only for the same socket key.
  # When specificity ties, keep the newer observation.
  defp prefer_socket_owner(current, candidate) do
    current_container? = present?(Map.get(current, :container_id))
    candidate_container? = present?(Map.get(candidate, :container_id))

    cond do
      candidate_container? and not current_container? ->
        candidate

      current_container? and not candidate_container? ->
        current

      DateTime.after?(Map.fetch!(candidate, :observed_at), Map.fetch!(current, :observed_at)) ->
        candidate

      true ->
        current
    end
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_), do: false

  defp execute_with_deadlock_retry(payload, query, sleep, retries_left, backoff) do
    case query.(@upsert_sql, [payload]) do
      {:error, %Postgrex.Error{} = error} when retries_left > 0 ->
        if deadlock?(error) do
          {delay_ms, next_backoff} = Backoff.next(backoff)
          sleep.(delay_ms)

          execute_with_deadlock_retry(
            payload,
            query,
            sleep,
            retries_left - 1,
            next_backoff
          )
        else
          {:error, error}
        end

      result ->
        result
    end
  end

  defp deadlock?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    Map.get(postgres, :code) == :deadlock_detected or
      Map.get(postgres, :code) == "40P01" or
      Map.get(postgres, :pg_code) == "40P01"
  end

  defp deadlock?(_error), do: false
end
