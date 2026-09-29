defmodule ServiceRadar.Edge.RangeStringStageTest do
  @moduledoc """
  Task 1.5-h: the address-string preflight RUNS, AND THE PARSER DOES NOT, for an input the
  preflight refuses -- observed through the real `PlanValidate.validate/2`.

  ## Why this exists when the verdicts are identical

  Everything the preflight refuses is also refused downstream in this runtime: zones by the
  canonical-spelling check, over-length values by the parser. So no VERDICT distinguishes a
  build with the preflight from one whose call has been replaced by a forged checked value --
  measured across zoned spans, zoned CIDRs and over-length values in every field.

  That made the preflight look unobservable, and it is not. CALL TRACING observes the stage
  directly, without changing production code and without giving the zone its own refusal
  reason -- that reason would be refusal taxonomy, which task 1.5-l owns.

  ## What each assertion carries

    * the PREFLIGHT is traced `:local`, because it is called from within its own module and a
      global pattern would never fire;
    * the PARSER is `:inet.parse_strict_address/1`, the function the preflight exists to keep
      an unchecked value away from;
    * a VALID control proves the parser trace is live. Without it "parser not called" is also
      what a broken trace pattern reports, and every refusal row would pass vacuously.

  `async: false`: trace patterns are node-global, so a concurrent test tracing the same MFA
  would see this one's calls and vice versa.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate

  @preflight {PlanValidate, :__check_range_strings__, 3}
  @parser {:inet, :parse_strict_address, 1}

  @fixtures Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  setup do
    # LOAD BEFORE PATTERNING. `trace_pattern/3` on a module the VM has not loaded yet matches
    # ZERO functions and reports so without raising, which is how the first test in this file
    # silently traced nothing while the rest passed -- a vacuity that looks like a real
    # "the preflight did not run" failure.
    {:module, _} = Code.ensure_loaded(PlanValidate)
    {:module, _} = Code.ensure_loaded(:inet)

    # The MATCH COUNT is asserted, so a renamed or inlined target cannot leave these rows
    # passing on an empty trace.
    assert :erlang.trace_pattern(@preflight, true, [:local]) >= 1,
           "the preflight trace pattern matched nothing"

    assert :erlang.trace_pattern(@parser, true, []) >= 1,
           "the parser trace pattern matched nothing"

    on_exit(fn ->
      :erlang.trace_pattern(@preflight, false, [:local])
      :erlang.trace_pattern(@parser, false, [])
    end)

    :ok
  end

  test "a VALID range reaches the parser -- the control that keeps the rows below honest" do
    calls =
      trace_validate(%{
        range()
        | cidr: "",
          first_address: "fe80::1",
          last_address: "fe80::1",
          target_count: 1
      })

    assert @preflight in calls, "the preflight must run for a valid range too"

    assert @parser in calls,
           "the parser trace is not live; every 'parser not called' assertion below would " <>
             "pass for that reason instead of the one it names"
  end

  test "a ZONED range is refused by the preflight, and the parser is never entered" do
    for {name, r} <- [
          {"span",
           %{range() | cidr: "", first_address: "fe80::1%eth0", last_address: "fe80::1%eth0"}},
          {"cidr", %{range() | cidr: "fe80::1%eth0/128", first_address: "", last_address: ""}}
        ] do
      calls = trace_validate(%{r | target_count: 1})

      assert @preflight in calls, "#{name}: the preflight did not run"

      refute @parser in calls,
             "#{name}: the address parser was entered for a zoned value -- the preflight is " <>
               "either not attached or not ahead of it"
    end
  end

  test "an OVER-LIMIT range is refused by the preflight, and the parser is never entered" do
    over = String.duplicate("z", 65)

    # THE CIDR VALUE MUST REACH THE PARSER when the preflight is bypassed, or the row proves
    # nothing. A run of 65 junk bytes carries no `/`, so `span_size/1` exits at the split
    # before `:inet.parse_strict_address/1` is ever called -- "parser not called" would then be
    # true with or without the preflight. This one is 65 bytes AND splits into a parseable
    # address with a 128 prefix, so the forged handoff genuinely reaches the parser.
    over_cidr = "fe80::1/" <> String.duplicate("0", 54) <> "128"

    for {name, r} <- [
          {"cidr", %{range() | cidr: over_cidr, first_address: "", last_address: ""}},
          {"first", %{range() | cidr: "", first_address: over, last_address: "fe80::1"}},
          {"last", %{range() | cidr: "", first_address: "fe80::1", last_address: over}}
        ] do
      calls = trace_validate(%{r | target_count: 1})

      assert @preflight in calls, "#{name}: the preflight did not run"

      refute @parser in calls,
             "#{name}: the address parser was entered for an over-limit value"
    end
  end

  # Runs the REAL validator in a traced worker and returns the set of traced MFAs it called.
  # A worker rather than the test process, so the trace covers exactly one validation and the
  # assertions cannot be satisfied by something the test framework did.
  defp trace_validate(r) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        _ = PlanValidate.validate(header_for(page_for(r)), [page_for(r)])
        send(test, {:done, self()})
      end)

    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    receive do
      {:done, ^pid} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> flunk("worker died: #{inspect(reason)}")
    after
      5_000 -> flunk("worker did not finish")
    end

    # DELIVERY IS SYNCHRONISED, not slept on. Trace messages reach the tracer asynchronously,
    # so a timeout-based drain can return before the last one arrives -- and a row that reads
    # "the parser was not called" would then be reporting a race. `trace_delivered/1` answers
    # once every trace message for this process has been delivered.
    delivery = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^delivery} -> :ok
    after
      5_000 -> flunk("trace delivery did not complete")
    end

    drain([])
  end

  defp drain(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> drain([{m, f, length(args)} | acc])
      {:DOWN, _, :process, _, _} -> drain(acc)
    after
      0 -> Enum.uniq(acc)
    end
  end

  defp page_for(r) do
    sealed = %{r | range_sha256: HashGrammar.range_digest(r)}
    p = %{page() | ranges: [sealed]}
    %{p | page_sha256: HashGrammar.plan_page_digest(p)}
  end

  defp header_for(page) do
    {:ok, commitment} = HashGrammar.plan_mtr_ordinal_range_commitment([page])

    h = %{
      header()
      | page_count: 1,
        plan_root_sha256: HashGrammar.plan_root([page]),
        total_target_count: hd(page.ranges).target_count,
        mtr_ordinal_range_commitment: commitment
    }

    %{h | execution_plan_sha256: HashGrammar.plan_header_digest(h)}
  end

  defp range, do: hd(page().ranges)

  defp page, do: "plan_page.bin" |> load() |> Serviceradar.Edge.V1.ScheduledPlanPageV1.decode()

  defp header,
    do: "plan_header.bin" |> load() |> Serviceradar.Edge.V1.ScheduledPlanHeaderV1.decode()

  defp load(name) do
    dir =
      [
        @fixtures,
        System.get_env("TEST_SRCDIR") &&
          Path.join([System.get_env("TEST_SRCDIR"), "_main", "proto/edge/v1/testdata"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.dir?/1)

    if !dir, do: flunk("shared fixture directory not found")
    File.read!(Path.join(dir, name))
  end
end
