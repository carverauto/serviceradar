defmodule ServiceRadar.CompositeChecks.SRQLEndToEndTest do
  @moduledoc """
  Runs the composite SRQL surfaces against a real database.

  This is the only coverage that proves the hand-transcribed Diesel schema in
  `rust/srql/src/schema.rs` matches the Elixir migrations. A wrong column name or
  type compiles cleanly and passes every SQL-shape assertion; it fails here, when
  Postgres actually executes the query.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.SRQLRunner

  @moduletag :integration

  defp actor, do: SystemActor.system(:composite_srql_test)

  defp device!(uid) do
    <<a, b, c, _rest::binary>> = :crypto.hash(:sha256, uid)

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: uid,
      hostname: "srql-#{a}-#{b}",
      ip: "10.#{a}.#{b}.#{max(c, 1)}"
    })
    |> Ash.create!(actor: actor())
  end

  defp verdict!(check, device_uid, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{"a" => %{"value" => "available"}},
        evaluated_at: now,
        changed_at: now
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  setup do
    {:ok, check} =
      CompositeCheck
      |> Ash.Changeset.for_create(
        :create,
        %{name: "E2E #{System.unique_integer([:positive])}", scope_query: "in:devices"},
        actor: actor()
      )
      |> Ash.create()

    {:ok, _rule} =
      CompositeCheckRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          check_id: check.id,
          position: 0,
          match: %{"a" => "available"},
          verdict: "not_isolated",
          verdict_label: "Not isolated",
          status: :down
        },
        actor: actor()
      )
      |> Ash.create()

    isolated = "e2e-isolated-#{System.unique_integer([:positive])}"
    exposed = "e2e-exposed-#{System.unique_integer([:positive])}"
    untested = "e2e-untested-#{System.unique_integer([:positive])}"

    for uid <- [isolated, exposed, untested], do: device!(uid)

    verdict!(check, isolated, "isolated_verified", :healthy)
    verdict!(check, exposed, "not_isolated", :down)

    %{check: check, isolated: isolated, exposed: exposed, untested: untested}
  end

  defp uids(rows), do: rows |> Enum.map(&(&1["uid"] || &1["device_uid"])) |> Enum.sort()

  describe "composite.<slug> device filter" do
    test "returns only devices holding the verdict", ctx do
      {:ok, rows} =
        SRQLRunner.query("in:devices composite.#{ctx.check.slug}:not_isolated limit:100")

      returned = uids(rows)

      assert ctx.exposed in returned
      refute ctx.isolated in returned
      refute ctx.untested in returned
    end

    test "filters by the fixed status enum", ctx do
      {:ok, rows} =
        SRQLRunner.query("in:devices composite.#{ctx.check.slug}.status:healthy limit:100")

      returned = uids(rows)

      assert ctx.isolated in returned
      refute ctx.exposed in returned
    end

    test "a list matches any of the given verdicts", ctx do
      {:ok, rows} =
        SRQLRunner.query(
          "in:devices composite.#{ctx.check.slug}:(not_isolated,isolated_verified) limit:100"
        )

      returned = uids(rows)

      assert ctx.exposed in returned
      assert ctx.isolated in returned
      refute ctx.untested in returned
    end

    test "an unknown slug returns nothing rather than everything", ctx do
      {:ok, rows} = SRQLRunner.query("in:devices composite.no-such-check:whatever limit:100")

      returned = uids(rows)

      refute ctx.isolated in returned
      refute ctx.exposed in returned
      refute ctx.untested in returned
    end

    test "a negated filter includes devices with no result for the check", ctx do
      {:ok, rows} =
        SRQLRunner.query("in:devices !composite.#{ctx.check.slug}:not_isolated limit:100")

      returned = uids(rows)

      assert ctx.isolated in returned
      # A device outside the check's scope does not hold that verdict either.
      assert ctx.untested in returned
      refute ctx.exposed in returned
    end
  end

  describe "in:composite_results" do
    test "returns a row per device with the check slug joined in", ctx do
      {:ok, rows} = SRQLRunner.query("in:composite_results check:#{ctx.check.slug} limit:100")

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1["check_slug"] == ctx.check.slug))
      assert uids(rows) == Enum.sort([ctx.isolated, ctx.exposed])
    end

    test "filters by verdict", ctx do
      {:ok, rows} =
        SRQLRunner.query(
          "in:composite_results check:#{ctx.check.slug} verdict:not_isolated limit:100"
        )

      assert [row] = rows
      assert row["device_uid"] == ctx.exposed
      assert row["verdict"] == "not_isolated"
    end

    test "filters by status", ctx do
      {:ok, rows} =
        SRQLRunner.query("in:composite_results check:#{ctx.check.slug} status:healthy limit:100")

      assert [row] = rows
      assert row["device_uid"] == ctx.isolated
    end

    test "carries the input snapshot and timestamps", ctx do
      {:ok, [row | _]} =
        SRQLRunner.query("in:composite_results check:#{ctx.check.slug} limit:1")

      assert is_map(row["inputs"])
      assert row["evaluated_at"]
      assert row["changed_at"]
      assert row["check_name"] == ctx.check.name
    end
  end
end
