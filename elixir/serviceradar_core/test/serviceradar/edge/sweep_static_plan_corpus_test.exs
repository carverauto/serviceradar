defmodule ServiceRadar.Edge.SweepStaticPlanCorpusTest do
  @moduledoc """
  M2.0b1: the shared static-target plan corpus, this runtime's half.

  `sweep_static_plan_corpus.txt` states one plan as literals. Go recomputes every digest with
  its own grammar and requires its own validator to accept the plan; this test builds the same
  plan from the RAW targets with `ServiceRadar.Edge.SweepPlan` and requires the same canonical
  text, count, range ids and digests. The expected digests come from Go, so a drift in either
  grammar fails here rather than showing up as an authorization the gateway refuses.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepPlan

  @corpus Path.expand(
            "../../../../../proto/edge/v1/testdata/sweep_static_plan_corpus.txt",
            __DIR__
          )
  @external_resource @corpus

  defp corpus do
    rows =
      @corpus
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.split/1)

    %{
      plan_id: rows |> single("plan_id") |> Base.decode16!(case: :lower),
      scope: rows |> single("network_scope_id") |> Base.decode16!(case: :lower),
      checks:
        for(
          ["check", m, p, port] <- rows,
          do: {String.to_integer(m), String.to_integer(p), String.to_integer(port)}
        ),
      targets:
        for(
          ["target", raw, cidr, count, range_id, sha] <- rows,
          do: %{
            raw: raw,
            cidr: cidr,
            count: String.to_integer(count),
            range_id: Base.decode16!(range_id, case: :lower),
            sha: sha
          }
        ),
      expect: expectations(rows)
    }
  end

  defp single(rows, key),
    do:
      Enum.find_value(rows, fn
        [^key, value] -> value
        _ -> nil
      end)

  defp expectations(rows) do
    for ["expect" | rest] <- rows, into: %{} do
      {key, [value]} = Enum.split(rest, -1)
      {Enum.join(key, " "), value}
    end
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)

  test "the plan built from the raw targets is the plan Go validates" do
    c = corpus()

    # Ranges take their ids from the corpus, in the order the plan lists its ranges.
    {:ok, ids} = Agent.start_link(fn -> Enum.map(c.targets, & &1.range_id) end)
    next_id = fn -> Agent.get_and_update(ids, fn [id | rest] -> {id, rest} end) end

    assert hex(SweepPlan.check_set_sha256(c.checks)) == c.expect["check_set_sha256"]

    # The targets arrive in the reverse of the plan's order: the builder orders them.
    assert {:ok, %{header: header, pages: [page]}} =
             c.targets
             |> Enum.map(& &1.raw)
             |> Enum.reverse()
             |> SweepPlan.build(
               plan_id: c.plan_id,
               network_scope_id: c.scope,
               check_set_sha256: SweepPlan.check_set_sha256(c.checks),
               range_id: next_id
             )

    assert Enum.map(page.ranges, &{&1.cidr, &1.target_count, &1.range_id}) ==
             Enum.map(c.targets, &{&1.cidr, &1.count, &1.range_id})

    assert Enum.map(page.ranges, &hex(&1.range_sha256)) == Enum.map(c.targets, & &1.sha)
    assert header.total_target_count == String.to_integer(c.expect["total_target_count"])
    assert hex(page.page_sha256) == c.expect["page_sha256 0"]
    assert hex(header.plan_root_sha256) == c.expect["plan_root"]
    assert hex(header.execution_plan_sha256) == c.expect["header_sha256"]
  end
end
