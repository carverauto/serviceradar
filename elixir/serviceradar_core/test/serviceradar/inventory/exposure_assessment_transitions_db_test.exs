defmodule ServiceRadar.Inventory.ExposureAssessmentTransitionsDbTest do
  @moduledoc """
  The transactional outbox contract of *Assessment Transitions Are Published On
  JetStream*, at the database boundary that owns it: the triggers on
  `endpoint_vulnerability_assessments`, whichever writer changes a row. The
  matcher lifecycle (enter, resolve on upgrade, unchanged rerun) is asserted in
  `EndpointVulnerabilityAssessmentMatcherTest`.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Inventory.ExposureDimensionRefreshWorker
  alias ServiceRadar.Inventory.ExposureDimensionRelay
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.ExposureTransitionCleanup

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    {:ok, unique: unique, device_uid: "sr:exposure-transition-#{unique}"}
  end

  test "an actionable attribute change publishes the complete after-image with ordinals; other writes publish nothing",
       ctx do
    cve_id = "CVE-2024-0001"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    assert [entered] = transitions(ctx.device_uid)
    assert entered["state"] == "active"
    assert entered["reason"] == "entered_actionable"
    assert entered["transition_seq"] == last_transition_seq(ctx.device_uid, cve_id)
    assert entered["cve_ord"] == 20_240_000_001
    assert is_integer(entered["pkg_ord"]) and is_integer(entered["pkgver_ord"])
    assert is_integer(entered["transition_xid"])
    assert is_binary(entered["first_exposed_at"])

    # Metadata, timestamps and the trigger-owned sequence column are not
    # exposure state: no transition, and the sequence cannot be overwritten.
    update_assessment!(ctx.device_uid, cve_id,
      metadata: %{"note" => "refreshed"},
      last_seen_at: ~N[2026-01-02 00:00:00],
      last_transition_seq: 1
    )

    assert [_entered] = transitions(ctx.device_uid)
    assert last_transition_seq(ctx.device_uid, cve_id) == entered["transition_seq"]

    update_assessment!(ctx.device_uid, cve_id, kev: true)

    assert [_entered, kev_changed] = transitions(ctx.device_uid)
    assert kev_changed["reason"] == "actionable_attributes_changed"
    assert kev_changed["changed_fields"] == ["kev"]
    assert kev_changed["transition_seq"] > entered["transition_seq"]
    # The after-image is complete: unchanged attributes are carried too.
    assert kev_changed["kev"] == true
    assert kev_changed["severity"] == "high"
    assert kev_changed["cvss_score"] == 7.5
    assert kev_changed["pkg_ord"] == entered["pkg_ord"]
    assert kev_changed["first_exposed_at"] == entered["first_exposed_at"]

    # A candidate is not exposure: neither its creation nor its changes publish.
    insert_assessment!(ctx, endpoint_package_ref, "CVE-2024-0002",
      assessment: "candidate",
      disposition: "unknown"
    )

    update_assessment!(ctx.device_uid, "CVE-2024-0002", severity: "critical")
    assert [_entered, _kev_changed] = transitions(ctx.device_uid)
  end

  test "deleting a published key resolves it at a new sequence and records its watermark; re-creating it clears the watermark",
       ctx do
    cve_id = "CVE-2024-0003"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)
    last = last_transition_seq(ctx.device_uid, cve_id)

    Repo.delete_all(
      from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
      prefix: "platform"
    )

    assert [_entered, deleted] = transitions(ctx.device_uid)
    assert deleted["state"] == "resolved"
    assert deleted["reason"] == "assessment_deleted"
    assert deleted["transition_seq"] > last
    assert is_binary(deleted["resolved_at"])

    assert [%{state: "resolved", transition_seq: watermark_seq}] = watermarks(ctx.device_uid)
    assert watermark_seq == deleted["transition_seq"]

    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    assert last_transition_seq(ctx.device_uid, cve_id) > watermark_seq
    assert watermarks(ctx.device_uid) == []
  end

  test "a rolled-back assessment change publishes nothing", ctx do
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               insert_assessment!(ctx, endpoint_package_ref, "CVE-2024-0004")
               assert [_entered] = transitions(ctx.device_uid)
               Repo.rollback(:rolled_back)
             end)

    assert transitions(ctx.device_uid) == []
  end

  test "CVE ordinals are deterministic for canonical identifiers and dictionary-backed above 10^12 otherwise" do
    ordinal = fn id ->
      %{rows: [[value]]} = Repo.query!("SELECT platform.exposure_cve_ordinal($1)", [id])
      value
    end

    assert ordinal.("CVE-2024-0001") == 20_240_000_001
    assert ordinal.("CVE-2024-1234567") == 20_241_234_567

    # An eight-digit sequence, a non-canonical leading zero and a non-CVE id
    # each get their own stable dictionary ordinal.
    for id <- ["CVE-2024-12345678", "CVE-2024-012345", "GHSA-0000-0000-0001"] do
      assert ordinal.(id) >= 1_000_000_000_000
      assert ordinal.(id) == ordinal.(id)
    end

    assert ordinal.("CVE-2024-012345") != ordinal.("CVE-2024-12345678")
  end

  # Two transactions change one assessment. The second waits on the first's row
  # lock, so it draws its sequence after the first commits.
  @tag sandbox: :unboxed
  test "concurrent changes to one assessment are sequenced in commit order", ctx do
    cve_id = "CVE-2024-0005"
    endpoint_package_ref = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, endpoint_package_ref, cve_id)

    on_exit(fn ->
      Repo.delete_all(
        from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
        prefix: "platform"
      )

      ExposureTransitionCleanup.delete_for_devices!([ctx.device_uid])

      Repo.delete_all(
        from(p in "endpoint_packages", where: p.id == ^Ecto.UUID.dump!(endpoint_package_ref)),
        prefix: "platform"
      )
    end)

    parent = self()

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          update_assessment!(ctx.device_uid, cve_id, cvss_score: 8.1)
          send(parent, :first_locked)

          receive do
            :commit -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :first_locked, 5_000

    second =
      Task.async(fn ->
        Repo.transaction(fn -> update_assessment!(ctx.device_uid, cve_id, kev: true) end)
      end)

    # The second update is blocked on the row lock until the first commits.
    refute Task.yield(second, 300)
    send(first.pid, :commit)
    assert {:ok, :ok} = Task.await(first, 10_000)
    assert {:ok, :ok} = Task.await(second, 10_000)

    assert [_entered, cvss, kev] = transitions(ctx.device_uid)
    assert cvss["changed_fields"] == ["cvss_score"]
    assert kev["changed_fields"] == ["kev"]
    assert kev["transition_seq"] > cvss["transition_seq"]
    # The later commit's after-image already includes the earlier change.
    assert kev["cvss_score"] == 8.1
  end

  test "dimension publication rolls back with its source and describes changed versions without duplicate writes",
       ctx do
    cve_id = "EXAMPLE-DIM-#{ctx.unique}"
    package = insert_endpoint_package!(ctx.unique)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               insert_assessment!(ctx, package, cve_id)
               assert length(dimension_messages(ctx, cve_id)) == 2
               Repo.rollback(:rollback)
             end)

    assert dimension_messages(ctx, cve_id) == []

    insert_assessment!(ctx, package, cve_id)
    [cve, first] = dimension_messages(ctx, cve_id)
    assert cve["cve_id"] == cve_id
    assert cve["epss_score"] == nil
    assert first["package_name"] == "examplelib"
    fact_seq = last_transition_seq(ctx.device_uid, cve_id)
    update_assessment!(ctx.device_uid, cve_id, package_name: "renamed-examplelib")
    assert last_transition_seq(ctx.device_uid, cve_id) == fact_seq
    [^cve, ^first, renamed] = dimension_messages(ctx, cve_id)
    assert renamed["package_name"] == "renamed-examplelib"
    assert renamed["transition_seq"] > first["transition_seq"]
    update_assessment!(ctx.device_uid, cve_id, package_name: "renamed-examplelib")
    assert dimension_messages(ctx, cve_id) == [cve, first, renamed]

    update_assessment!(ctx.device_uid, cve_id, installed_version: "2.0.0")
    [^cve, ^first, ^renamed, upgraded] = dimension_messages(ctx, cve_id)
    assert upgraded["pkg_ord"] == first["pkg_ord"]
    refute upgraded["pkgver_ord"] == first["pkgver_ord"]
    assert upgraded["installed_version"] == "2.0.0"

    Repo.delete_all(
      from(a in "endpoint_vulnerability_assessments", where: a.device_uid == ^ctx.device_uid),
      prefix: "platform"
    )

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.exposure_dimension_state WHERE content->>'package_identity_key' = $1",
               ["pkgkey:examplelib:#{ctx.unique}"]
             )
  end

  test "daily priority refresh changes and clears EPSS without rewriting assessments", ctx do
    cve_id = "EXAMPLE-EPSS-#{ctx.unique}"
    feed = "example-dimension-#{ctx.unique}"
    package = insert_endpoint_package!(ctx.unique)
    insert_assessment!(ctx, package, cve_id)
    original = transitions(ctx.device_uid)

    Repo.insert_all(
      "vulnerability_feed_definitions",
      [
        %{
          provider: "example",
          feed_key: feed,
          display_name: "Synthetic dimension feed",
          feed_type: "kev",
          enabled: true
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "vulnerability_advisories",
      [
        %{
          provider: "example",
          feed_key: feed,
          source_object_id: cve_id,
          advisory_id: cve_id,
          cve_id: cve_id,
          kev: true,
          current: true,
          metadata: %{"priority" => %{"epss_score" => 0.0}}
        }
      ],
      prefix: "platform"
    )

    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    after_refresh = dimension_messages(ctx, cve_id)
    assert List.last(after_refresh)["epss_score"] == 0.0
    assert transitions(ctx.device_uid) == original
    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    assert dimension_messages(ctx, cve_id) == after_refresh

    # A later fact transition re-registers identity without losing enrichment.
    update_assessment!(ctx.device_uid, cve_id, kev: true)
    assert dimension_messages(ctx, cve_id) == after_refresh

    Repo.update_all(
      from(f in "vulnerability_feed_definitions", where: f.feed_key == ^feed),
      [set: [enabled: false]],
      prefix: "platform"
    )

    assert :ok = ExposureDimensionRefreshWorker.perform(%Oban.Job{})
    cleared = List.last(dimension_messages(ctx, cve_id))
    assert Map.has_key?(cleared, "epss_score") and cleared["epss_score"] == nil
    assert cleared["transition_seq"] > List.last(after_refresh)["transition_seq"]
    assert ctx.device_uid |> transitions() |> length() == 2
  end

  test "dimension relay retains the exact failed publication until PubAck", ctx do
    cve_id = "EXAMPLE-RELAY-#{ctx.unique}"
    insert_assessment!(ctx, insert_endpoint_package!(ctx.unique), cve_id)
    [expected_cve, expected_package] = dimension_messages(ctx, cve_id)
    parent = self()

    publish = fn subject, body, opts ->
      payload = Jason.decode!(body)

      if payload in [expected_cve, expected_package],
        do: send(parent, {:dimension, subject, payload, opts[:msg_id]})

      if payload == expected_package, do: {:error, :timeout}, else: :ok
    end

    assert {:ok, %{failed: 1}} =
             ExposureDimensionRelay.relay_once(
               batch_size: 100_000,
               publish: publish,
               ensure_stream: fn _ -> :ok end
             )

    assert_received {:dimension, "exposure.dimensions.cve", ^expected_cve, cve_msg_id}
    assert_received {:dimension, "exposure.dimensions.package", ^expected_package, package_msg_id}
    assert cve_msg_id == "exposure-dimension-#{expected_cve["transition_seq"]}"
    assert package_msg_id == "exposure-dimension-#{expected_package["transition_seq"]}"
    assert dimension_messages(ctx, cve_id) == [expected_package]

    assert {:ok, %{failed: 0}} =
             ExposureDimensionRelay.relay_once(
               publish: fn subject, body, opts ->
                 send(parent, {:retried, subject, Jason.decode!(body), opts[:msg_id]})
                 :ok
               end
             )

    assert_received {:retried, "exposure.dimensions.package", ^expected_package, ^package_msg_id}
    assert dimension_messages(ctx, cve_id) == []
  end

  @tag sandbox: :unboxed
  test "dimension creation and equal-content races serialize before allocating sequences", ctx do
    for {offset, initial, first_score, final_score} <- [{0, nil, 0.1, 0.9}, {1, 0.1, 0.9, 0.1}] do
      ordinal = 2_000_000_000_000 + ctx.unique * 2 + offset

      content = %{
        "cve_ord" => ordinal,
        "cve_id" => "EXAMPLE-CONCURRENT-#{ordinal}",
        "epss_score" => initial
      }

      on_exit(fn ->
        for table <- ["exposure_dimension_outbox", "exposure_dimension_state"] do
          Repo.delete_all(
            from(row in table, where: row.kind == "cve" and row.ordinal == ^ordinal),
            prefix: "platform"
          )
        end
      end)

      if initial do
        Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
          ordinal,
          content
        ])
      end

      parent = self()

      first =
        Task.async(fn ->
          Repo.transaction(fn ->
            %{rows: [[seq]]} =
              Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
                ordinal,
                %{content | "epss_score" => first_score}
              ])

            send(parent, {:created, seq})

            receive do
              :commit -> seq
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:created, first_seq}, 5_000

      second =
        Task.async(fn ->
          Repo.query!("SELECT platform.exposure_publish_dimension('cve', $1, $2)", [
            ordinal,
            %{content | "epss_score" => final_score}
          ])
        end)

      refute Task.yield(second, 300)
      send(first.pid, :commit)
      assert {:ok, ^first_seq} = Task.await(first, 10_000)
      assert %{rows: [[second_seq]]} = Task.await(second, 10_000)
      assert second_seq > first_seq

      assert %{rows: [[^final_score]]} =
               Repo.query!(
                 "SELECT (content->>'epss_score')::float8 FROM platform.exposure_dimension_state WHERE kind = 'cve' AND ordinal = $1",
                 [ordinal]
               )
    end
  end

  defp dimension_messages(ctx, cve_id) do
    key = "pkgkey:examplelib:#{ctx.unique}"

    Repo.all(
      from(o in "exposure_dimension_outbox",
        where:
          fragment("?->>'package_identity_key'", o.payload) == ^key or
            fragment("?->>'cve_id'", o.payload) == ^cve_id,
        order_by: [asc: o.id],
        select: o.payload
      ),
      prefix: "platform"
    )
  end

  defp insert_endpoint_package!(unique) do
    endpoint_package_ref = Ecto.UUID.generate()

    Repo.insert_all(
      "endpoint_packages",
      [
        %{
          id: Ecto.UUID.dump!(endpoint_package_ref),
          coordinate_key: "exposure-transition-#{unique}",
          cpes: [],
          package_manager: "dpkg",
          name: "examplelib",
          version: "1.0.0",
          source_scope: "host",
          metadata: %{}
        }
      ],
      prefix: "platform"
    )

    endpoint_package_ref
  end

  defp insert_assessment!(ctx, endpoint_package_ref, cve_id, attrs \\ []) do
    now = ~N[2026-01-01 00:00:00]

    row =
      Map.merge(
        %{
          device_uid: ctx.device_uid,
          package_identity_key: "pkgkey:examplelib:#{ctx.unique}",
          source_scope: "host",
          endpoint_package_ref: Ecto.UUID.dump!(endpoint_package_ref),
          cve_id: cve_id,
          status: "active",
          assessment: "confirmed",
          disposition: "affected",
          applicability_reason: "synthetic",
          freshness: "fresh",
          package_name: "examplelib",
          installed_version: "1.0.0",
          severity: "high",
          cvss_score: 7.5,
          supporting_match_ids: [],
          supporting_assertion_ids: [],
          evidence: %{},
          metadata: %{},
          first_seen_at: now,
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        },
        Map.new(attrs)
      )

    Repo.insert_all("endpoint_vulnerability_assessments", [row], prefix: "platform")
    :ok
  end

  defp update_assessment!(device_uid, cve_id, set) do
    {1, _} =
      Repo.update_all(
        from(a in "endpoint_vulnerability_assessments",
          where: a.device_uid == ^device_uid and a.cve_id == ^cve_id
        ),
        [set: set],
        prefix: "platform"
      )

    :ok
  end

  defp last_transition_seq(device_uid, cve_id) do
    Repo.one(
      from(a in "endpoint_vulnerability_assessments",
        where: a.device_uid == ^device_uid and a.cve_id == ^cve_id,
        select: a.last_transition_seq
      ),
      prefix: "platform"
    )
  end

  defp transitions(device_uid) do
    Repo.all(
      from(o in "exposure_transition_outbox",
        where: o.device_uid == ^device_uid,
        order_by: [asc: o.id],
        select: o.payload
      ),
      prefix: "platform"
    )
  end

  defp watermarks(device_uid) do
    Repo.all(
      from(w in "exposure_fact_watermarks",
        where: w.device_uid == ^device_uid,
        select: %{state: w.state, transition_seq: w.transition_seq}
      ),
      prefix: "platform"
    )
  end
end
