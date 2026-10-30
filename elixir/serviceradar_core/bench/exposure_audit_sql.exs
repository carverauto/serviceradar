defmodule ServiceRadar.ExposureAudit.SQL do
  @moduledoc "SQL projection for the manual, disabled audit prototype. The production v1 digest is the oracle."
  import ExUnit.Assertions

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.ExposureAudit.Receipts
  alias ServiceRadar.Inventory.ExposureReconciliationDigest, as: Digest
  alias ServiceRadar.Repo

  @columns ~w(device_ord cve_ord pkg_ord transition_seq device_lifecycle_seq pkgver_ord state
              severity_rank cvss_score kev exploit_available fix_available source_scope)
  @flags ~w(kev exploit_available fix_available)
  @modulus Integer.pow(2, 256)

  def source!(reader, run, ordinals) do
    rows = Postgrex.query!(reader, source_sql(), [run.id, ordinals], timeout: 30_000).rows

    counters = %{
      assessment_rows: 0,
      reference_occurrences: 0,
      reference_memberships: 0,
      dimension_keys: 0
    }

    {summaries, work} =
      Enum.map_reduce(rows, counters, fn [ordinal | values], totals ->
        {digest,
         [drift, missing, checked_at, assessments, refs, memberships, keys, receipt_misses]} =
          Enum.split(values, 9)

        totals = %{
          assessment_rows: totals.assessment_rows + assessments,
          reference_occurrences: totals.reference_occurrences + refs,
          reference_memberships: totals.reference_memberships + memberships,
          dimension_keys: keys
        }

        {{ordinal, {summary(digest), drift, missing, checked_at, receipt_misses}}, totals}
      end)

    {Map.new(summaries), work}
  end

  def explain_source!(reader, run, ordinals) do
    [[plan]] =
      Postgrex.query!(
        reader,
        "EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT JSON) " <> source_sql(),
        [run.id, ordinals],
        timeout: 30_000
      ).rows

    IO.puts("EXPOSURE_AUDIT_PLAN " <> Jason.encode!(%{query: "source_and_coverage", plan: plan}))
  end

  defp source_sql do
    sums = Enum.map_join(0..7, ",", &"COALESCE(f.s#{&1},0)")
    names = Enum.map_join(0..7, ",", &"s#{&1}")

    """
    WITH cohort AS MATERIALIZED (
      SELECT ordinal,uid,lifecycle_seq,tombstoned FROM platform.device_fleet_ordinals
      WHERE ordinal=ANY($2)
    ), #{source_projection_sql()},
    fact_totals(ordinal,n,#{names},drift,assessment_rows,receipt_misses) AS (
      SELECT ordinal,count(h),#{limbs(:pg)},count(*) FILTER (WHERE drift),count(*),
        count(*) FILTER (WHERE receipt_miss)
      FROM compact GROUP BY ordinal
    ), #{source_coverage_sql()}
    SELECT requested.ordinal,COALESCE(f.n,0),#{sums},COALESCE(f.drift,0),
      COALESCE(c.missing,0),c.checked_at,COALESCE(f.assessment_rows,0),
      COALESCE(r.n,0),COALESCE(c.memberships,0),(SELECT count(*) FROM dimension_keys),COALESCE(f.receipt_misses,0)
    FROM unnest($2::bigint[]) AS requested(ordinal)
    LEFT JOIN fact_totals f USING(ordinal)
    LEFT JOIN coverage c USING(ordinal)
    LEFT JOIN reference_counts r USING(ordinal)
    """
  end

  defp source_projection_sql do
    fields = Map.new(@columns, &{&1, "current_#{&1}"})

    # The receipt binds full replay validation, not the current source values.
    # Hash those values once per audit; reuse neither a current nor warehouse hash.
    """
    input AS NOT MATERIALIZED (
      SELECT o.ordinal,NOT o.tombstoned AS fact_scope,
        r.assessment_id IS NULL AS receipt_miss,COALESCE(r.valid_after_image,false) AS valid_replay,
        r.cve_ord AS ref_cve,r.pkgver_ord AS ref_package,r.replay_state,
        encode(r.replay_digest,'hex') AS replay_digest,
        r.cve_ord AS current_cve_ord,r.pkg_ord AS current_pkg_ord,
        o.ordinal AS current_device_ord,
        a.last_transition_seq AS current_transition_seq,o.lifecycle_seq AS current_device_lifecycle_seq,
        v.ordinal AS current_pkgver_ord,
        CASE WHEN platform.exposure_assessment_actionable(a.status,a.assessment,a.disposition)
          THEN 1 ELSE 0 END AS current_state,
        #{severity("a.severity")} AS current_severity_rank,
        a.cvss_score::double precision AS current_cvss_score,
        a.kev AS current_kev,a.exploit_available AS current_exploit_available,
        COALESCE(btrim(a.fixed_version),'') <> '' AS current_fix_available,
        a.source_scope AS current_source_scope
      FROM cohort o
      JOIN platform.endpoint_vulnerability_assessments a ON a.device_uid=o.uid
      LEFT JOIN platform.exposure_package_version_ordinals v
        ON v.package_identity_key=a.package_identity_key AND v.installed_version=COALESCE(a.installed_version,'')
      LEFT JOIN platform.exposure_audit_receipts r ON r.assessment_id=a.id
        AND r.payload_hash=a.audit_publication_hash AND r.validator_revision=#{Receipts.revision()}
    ), typed AS NOT MATERIALIZED (
      SELECT *,
        COALESCE(valid_replay AND current_transition_seq > current_device_lifecycle_seq
          AND current_device_lifecycle_seq >= 0 AND current_pkgver_ord > 0
          AND (current_cvss_score IS NULL OR current_cvss_score BETWEEN 0 AND 10)
          AND (current_source_scope IS NULL OR octet_length(current_source_scope)<=32),false) AS valid
      FROM input
    ), hashed AS MATERIALIZED (
      SELECT ordinal,ref_cve,ref_package,receipt_miss,fact_scope,valid,current_state,replay_state,replay_digest,
        CASE WHEN fact_scope AND valid AND current_state=1 THEN #{hash(:pg, fields)} END AS h
      FROM typed
    ), compact AS MATERIALIZED (
      SELECT ordinal,ref_cve,ref_package,receipt_miss,h,
        CASE WHEN NOT fact_scope THEN false
          WHEN NOT valid THEN true
          WHEN current_state=0 AND replay_state=0 THEN false
          ELSE h IS DISTINCT FROM replay_digest END AS drift
      FROM hashed
    )
    """
  end

  defp source_coverage_sql do
    """
    covering AS MATERIALIZED (
      SELECT o.ordinal,g.updated_at FROM cohort o
      LEFT JOIN LATERAL (SELECT updated_at FROM platform.exposure_snapshot_generations
        WHERE status='complete' AND (control->>'scope' IS NULL OR (control->>'scope')::bigint=o.ordinal)
        ORDER BY id DESC LIMIT 1) g ON true
    ), reference_rows AS MATERIALIZED (
      SELECT ordinal,k.kind,k.key FROM compact CROSS JOIN LATERAL
        (VALUES ('cve',ref_cve),('package',ref_package)) k(kind,key)
      UNION ALL
      SELECT o.ordinal,k.kind,k.key FROM cohort o
      JOIN platform.exposure_fact_watermarks w ON w.device_uid=o.uid
      CROSS JOIN LATERAL (VALUES
        ('cve',#{reference_ordinal("w.payload", "cve_ord")}),
        ('package',#{reference_ordinal("w.payload", "pkgver_ord")})) k(kind,key)
    ), reference_counts AS (
      SELECT ordinal,count(*) AS n FROM reference_rows GROUP BY ordinal
    ), memberships AS MATERIALIZED (
      SELECT DISTINCT ordinal,kind,key FROM reference_rows
    ), dimension_keys AS MATERIALIZED (
      SELECT DISTINCT kind,key FROM memberships
    ), verified_keys AS MATERIALIZED (
      SELECT k.kind,k.key,d.ordinal AS source_key,p.checked_at
      FROM dimension_keys k
      LEFT JOIN platform.exposure_dimension_state d ON d.kind=k.kind AND d.ordinal=k.key
      LEFT JOIN platform.exposure_audit_proofs p ON p.run_id=$1::text::uuid AND p.kind=d.kind
        AND p.ordinal=d.ordinal AND p.source_seq=d.transition_seq AND p.source_hash=d.audit_content_hash
    ), coverage AS (
      SELECT m.ordinal,count(*) AS memberships,
        count(*) FILTER(WHERE v.source_key IS NULL OR v.checked_at IS NULL OR v.checked_at<g.updated_at) AS missing,
        min(v.checked_at) AS checked_at
      FROM memberships m LEFT JOIN verified_keys v ON v.kind=m.kind AND v.key=m.key
      LEFT JOIN covering g ON g.ordinal=m.ordinal GROUP BY m.ordinal
    )
    """
  end

  # A malformed reference remains a NULL membership and therefore a coverage
  # failure. It must neither raise an unsafe cast nor vanish behind a filter.
  defp reference_ordinal(payload, key) do
    "CASE WHEN #{integer_json(payload, key, 1, 9_223_372_036_854_775_807)} " <>
      "THEN (#{payload}->>'#{key}')::bigint END"
  end

  # This validator is independently compared to ExposureTransitions.decode/1.
  # CASE protects casts; invalid JSON never disappears behind a WHERE filter.
  def valid_publication(p) do
    required =
      ~w(device_ord cve_ord pkg_ord pkgver_ord transition_seq transition_xid state source_scope
                  severity cvss_score kev exploit_available fix_available first_exposed_at resolved_at changed_at)

    keys = Enum.map_join(required, ",", &"'#{&1}'")

    integers =
      Enum.map_join(
        ~w(cve_ord pkg_ord pkgver_ord transition_seq transition_xid),
        " AND ",
        &integer_json(p, &1, 1, 9_223_372_036_854_775_807)
      )

    flags = Enum.map_join(@flags, " AND ", &"jsonb_typeof(#{p}->'#{&1}') IN ('null','boolean')")
    lifecycle = "COALESCE(#{p}->'device_lifecycle_seq','0'::jsonb)"

    """
    (jsonb_typeof(#{p})='object' AND jsonb_typeof(#{p}->'schema_version')='number' AND #{p}->>'schema_version'='1'
      AND #{p} ?& ARRAY[#{keys}] AND (#{integers})
      AND #{integer_json(p, "device_ord", 1, 4_294_967_295)}
      AND CASE WHEN jsonb_typeof(#{lifecycle})='number' AND (#{lifecycle})::text ~ '^[0-9]+$'
        AND jsonb_typeof(#{p}->'transition_seq')='number'
        THEN (#{lifecycle})::text::numeric < (#{p}->>'transition_seq')::numeric ELSE false END
      AND COALESCE(#{p}->>'event_type','') NOT IN ('device_retired','device_restored')
      AND #{p}->>'state' IN ('active','resolved')
      AND (jsonb_typeof(#{p}->'severity') IN ('null','string'))
      AND (jsonb_typeof(#{p}->'source_scope')='null' OR
        (jsonb_typeof(#{p}->'source_scope')='string' AND octet_length(#{p}->>'source_scope')<=32))
      AND CASE WHEN jsonb_typeof(#{p}->'cvss_score')='null' THEN true
        WHEN jsonb_typeof(#{p}->'cvss_score')='number' THEN (#{p}->>'cvss_score')::numeric BETWEEN 0 AND 10
        ELSE false END
      AND (#{flags}) AND #{datetime(p, "changed_at", false)}
      AND #{datetime(p, "first_exposed_at", true)} AND #{datetime(p, "resolved_at", true)})
    """
  end

  defp integer_json(p, key, low, high) do
    "CASE WHEN jsonb_typeof(#{p}->'#{key}')='number' AND (#{p}->>'#{key}') ~ '^[0-9]+$' " <>
      "THEN (#{p}->>'#{key}')::numeric BETWEEN #{low} AND #{high} ELSE false END"
  end

  defp datetime(p, key, nullable) do
    null = if nullable, do: "jsonb_typeof(#{p}->'#{key}')='null' OR ", else: ""
    value = "(#{p}->>'#{key}')"
    # NaiveDateTime discards a valid offset and truncates arbitrary fractional
    # precision. Map the year into an equivalent Gregorian 400-year cycle so
    # PostgreSQL's lack of year zero cannot reject a valid Elixir date.
    pattern =
      "^[+-]?[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[T ]" <>
        "([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.,][0-9]+)?" <>
        "(Z|[+-]([01][0-9]|2[0-3])(:?[0-5][0-9])?)?$"

    date = "ltrim(#{value},'+-')"

    "(#{null}CASE WHEN jsonb_typeof(#{p}->'#{key}')='string' AND #{value} ~ '#{pattern}' " <>
      "AND #{value} !~ '-00:00$' THEN pg_input_is_valid(" <>
      "(2000 + substring(#{date},1,4)::integer % 400)::text || substring(#{date},5,6),'date') ELSE false END)"
  end

  defp severity(value),
    do:
      "CASE lower(#{value}) WHEN 'none' THEN 0 WHEN 'unknown' THEN 0 WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 WHEN 'critical' THEN 4 END"

  def verify_digest! do
    base = Map.new(@columns, &{&1, 1})

    base =
      Map.merge(base, %{
        "device_lifecycle_seq" => 0,
        "cvss_score" => 7.5,
        "kev" => true,
        "exploit_available" => false,
        "fix_available" => nil,
        "source_scope" => "host"
      })

    cases = [
      base,
      Map.merge(base, %{"cvss_score" => nil, "severity_rank" => nil, "source_scope" => nil}),
      Map.merge(base, %{
        "cvss_score" => -0.0,
        "kev" => 0,
        "exploit_available" => 1,
        "source_scope" => ""
      }),
      Map.merge(base, %{
        "device_ord" => 4_294_967_295,
        "cve_ord" => 9_223_372_036_854_775_807,
        "cvss_score" => 0.1,
        "source_scope" => "höst-λ"
      }),
      Map.merge(base, %{
        "cvss_score" => 10.0,
        "source_scope" => "01234567890123456789012345678901"
      }),
      Map.put(base, "cvss_score", 1.2345678901234567),
      Map.put(base, "cvss_score", 5.0e-324),
      Map.merge(base, %{"kev" => nil, "exploit_available" => nil, "fix_available" => true}),
      Map.put(base, "fix_available", false),
      Map.merge(base, %{"state" => 0, "cvss_score" => nil}),
      Map.merge(base, %{"state" => 2, "pkgver_ord" => 0, "cvss_score" => nil})
    ]

    # The existing production digest, not either SQL implementation, is the
    # oracle. Test individually and together to cover carries and null handling.
    for {rows, index} <- Enum.with_index(Enum.map(cases, &[&1]) ++ [cases, cases ++ cases]) do
      expected = Enum.reduce(rows, Digest.empty(), &Digest.add(&2, &1))

      for dialect <- [:pg, :warehouse] do
        input = Enum.map_join(rows, " UNION ALL ", &literal_row(&1, dialect))

        sql =
          "SELECT count(*), #{limbs(dialect)} FROM (SELECT #{hash(dialect)} AS h FROM (#{input}) facts WHERE state=1) hashes"

        [summary] = if dialect == :pg, do: Repo.query!(sql).rows, else: warehouse!(sql)
        actual = summary(summary)

        assert actual == expected,
               "typed digest differs in #{dialect}, case #{index}: #{inspect(actual)} != #{inspect(expected)}"
      end
    end

    IO.puts(
      "EXPOSURE_AUDIT_PARITY " <>
        Jason.encode!(%{cases: length(cases), aggregates: 2, engines: 2, passed: true})
    )
  end

  def warehouse_summary!(ordinals) do
    assert Enum.all?(ordinals, &(is_integer(&1) and &1 in 1..4_294_967_295))

    sql = """
    SELECT device_ord,count(*),#{limbs(:warehouse)} FROM (
      SELECT device_ord,#{hash(:warehouse)} AS h FROM exposure_facts
      WHERE device_ord IN (#{Enum.join(ordinals, ",")}) AND state=1
    ) hashes GROUP BY device_ord
    """

    Map.new(warehouse!(sql), fn [ordinal | values] -> {ordinal, summary(values)} end)
  end

  defp hash(dialect, fields \\ %{}) do
    parts =
      Enum.map(@columns, fn column ->
        typed_hex(dialect, column, Map.get(fields, column, column))
      end)

    bytes = "concat('6578706f737572652d666163742f7631'," <> Enum.join(parts, ",") <> ")"

    case dialect do
      :pg -> "encode(sha256(decode(#{bytes},'hex')),'hex')"
      :warehouse -> "sha2(to_binary(#{bytes},'hex'),256)"
    end
  end

  defp typed_hex(dialect, column, value) do
    encoded =
      cond do
        column in @flags ->
          "CASE WHEN #{value} THEN '0201' ELSE '0200' END"

        column == "source_scope" and dialect == :pg ->
          "concat('03',encode(int4send(octet_length(#{value})),'hex'),encode(convert_to(#{value},'UTF8'),'hex'))"

        column == "source_scope" ->
          "concat('03',lpad(hex(length(#{value})),8,'0'),hex(#{value}))"

        column == "cvss_score" and dialect == :pg ->
          "concat('04',encode(float8send(CASE WHEN #{value}=0 THEN 0::double precision ELSE #{value} END),'hex'))"

        column == "cvss_score" ->
          # encode_sort_key's native DOUBLE encoding prefixes 01 and flips the
          # sign bit of nonnegative IEEE-754 values. CVSS is restricted to 0..10.
          # Zero is normalized separately, exactly as the production digest does.
          key = "hex(encode_sort_key(CAST(#{value} AS DOUBLE)))"

          "CASE WHEN #{key} IN ('018000000000000000','017FFFFFFFFFFFFFFF') THEN '040000000000000000' ELSE concat('04',substring('01234567',cast(conv(substring(#{key},3,1),16,10) AS INT)-7,1),substring(#{key},4,15)) END"

        dialect == :pg ->
          "concat('01',encode(int8send((#{value})::bigint),'hex'))"

        true ->
          "concat('01',lpad(hex(CAST(#{value} AS BIGINT)),16,'0'))"
      end

    "CASE WHEN #{value} IS NULL THEN '00' ELSE #{encoded} END"
  end

  defp limbs(dialect) do
    Enum.map_join(0..7, ",", fn index ->
      part = "substring(h,#{index * 8 + 1},8)"

      case dialect do
        :pg -> "COALESCE(sum(('x'||#{part})::bit(32)::bigint),0)"
        :warehouse -> "COALESCE(sum(CAST(conv(#{part},16,10) AS LARGEINT)),0)"
      end
    end)
  end

  defp summary([count | limbs]) do
    assert length(limbs) == 8
    sum = Enum.reduce(limbs, 0, fn limb, acc -> acc * 4_294_967_296 + integer(limb) end)
    %{count: count, sum: rem(sum, @modulus)}
  end

  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value) when is_binary(value), do: String.to_integer(value)
  defp integer(value) when is_integer(value), do: value

  defp literal_row(row, dialect) do
    "SELECT " <>
      Enum.map_join(@columns, ",", fn column ->
        value = Map.fetch!(row, column)

        literal =
          cond do
            is_nil(value) -> "NULL"
            column in @flags -> if value in [true, 1], do: "true", else: "false"
            is_binary(value) -> "'" <> String.replace(value, "'", "''") <> "'"
            is_float(value) -> "'" <> Float.to_string(value) <> "'"
            true -> to_string(value)
          end

        type =
          cond do
            column == "source_scope" -> if dialect == :pg, do: "text", else: "varchar"
            column == "cvss_score" -> if dialect == :pg, do: "double precision", else: "double"
            column in @flags -> "boolean"
            true -> "bigint"
          end

        "CAST(#{literal} AS #{type}) AS #{column}"
      end)
  end

  def warehouse!(sql) do
    {:ok, %{rows: rows}} = MySQL.query(sql, timeout: 30_000)
    rows
  end
end
