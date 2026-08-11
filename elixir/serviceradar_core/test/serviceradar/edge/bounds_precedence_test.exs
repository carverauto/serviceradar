defmodule ServiceRadar.Edge.BoundsPrecedenceTest do
  @moduledoc """
  Task 1.5-h: STRUCTURAL COUNT CEILINGS FIRE BEFORE THE RECURSIVE WALK THEY BOUND, and the
  counting itself does not perform the traversal the ceiling forbids.

  Peer of Go's `bounds_precedence_test.go`. Every assertion here is about PRECEDENCE or about
  TRAVERSAL COST, never about a verdict: this runtime returned the correct verdict before the
  change and after it, so an N/N+1 pair passes in both directions while `no_unknown_fields?/1`
  descends into every span of every page and `length/1` walks the whole supplied list.

  ## Why the improper-tail trick is the proof, not a timing measurement

  A timing assertion would be flaky and would not say WHERE the walk stopped. An improper list
  answers it exactly: `List.duplicate(:x, cap + 1) ++ :garbage` reports `:over` if and only if
  the walk stopped at `cap + 1`, and `:improper` if anything walked to the end. One boolean,
  fully deterministic, and it fails the moment someone reintroduces `length/1`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias ServiceRadar.Edge.WireShape

  @cap 8
  @max_pages 1024
  @max_ranges 256

  describe "BoundedList walks at most cap+1 cells" do
    test "counts a list at or under the cap" do
      assert BoundedList.count_at_most([], @cap) == {:ok, 0}
      assert BoundedList.count_at_most(List.duplicate(:x, @cap), @cap) == {:ok, @cap}
    end

    test "reports :over at cap+1 WITHOUT reaching the tail" do
      # THE BOUNDED-TRAVERSAL PROOF. The tail is not a list, so anything that walks past
      # cap+1 reports :improper. Getting :over is only possible if the walk stopped.
      beyond = List.duplicate(:x, @cap + 1) ++ :never_reached
      assert BoundedList.count_at_most(beyond, @cap) == :over

      # And the same shape UNDER the cap does reach the tail, which is what proves the
      # assertion above is not passing for some unrelated reason.
      short = List.duplicate(:x, @cap - 1) ++ :reached
      assert BoundedList.count_at_most(short, @cap) == :improper
    end

    test "an improper list within the cap is :improper, never a count" do
      assert BoundedList.count_at_most([:a, :b | :tail], @cap) == :improper
      refute BoundedList.within?([:a, :b | :tail], @cap)
      refute BoundedList.nonempty_within?([:a, :b | :tail], @cap)
    end

    test "nonempty_within? separates empty from over" do
      refute BoundedList.nonempty_within?([], @cap)
      assert BoundedList.nonempty_within?([:x], @cap)
      assert BoundedList.nonempty_within?(List.duplicate(:x, @cap), @cap)
      refute BoundedList.nonempty_within?(List.duplicate(:x, @cap + 1), @cap)
    end
  end

  describe "recovery manifest ceilings precede the unknown-field walk" do
    setup do
      %{page: go_page()}
    end

    test "the page-list ceiling fires before the walk", %{page: page} do
      limits = RecoveryValidate.limits()

      # ONE taint, on the LAST page's LAST span. Tainting every page lets the walk stop on
      # page one, which proves nothing about traversing an oversize LIST -- the ceiling this
      # test names bounds the list, so the walk must be shown to reach its end.
      over = List.duplicate(page, limits.max_manifest_pages) ++ [taint(page)]

      # If the walk ran first this would be :unknown_fields -- a refusal, just not this one.
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain(over, nil)
    end

    test "the per-page span ceiling fires before the walk", %{page: page} do
      limits = RecoveryValidate.limits()
      span = hd(page.classification_spans)

      fat =
        taint(%{page | classification_spans: List.duplicate(span, limits.max_spans_per_page + 1)})

      # A LEGAL page count, so the list ceiling cannot be what refuses this.
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain([fat], nil)
    end

    test "the unknown-field walk still precedes the SEMANTIC rules", %{page: page} do
      # The control that keeps the two above honest: the ceilings moved ahead of the walk,
      # not ahead of everything. Counts are legal here, so a tainted page whose chain is also
      # broken must still report the unknown field.
      broken = taint(%{page | page_index: 99})

      assert {:error, :unknown_fields} = RecoveryValidate.manifest_chain([broken], nil)
    end

    test "a partial page map is refused, not raised", %{page: page} do
      # The count ceilings run ahead of the structural walk, so every field read below them
      # sees shapes nothing validated. A map carrying only the two keys the ceilings touch
      # would satisfy a key-presence guard and then raise on page_index, page_count,
      # prev_page_sha256 or terminal -- which is why the guard demands the GENERATED STRUCT.
      partial = %{recovery_id: page.recovery_id, classification_spans: page.classification_spans}

      assert {:error, :manifest_chain} = RecoveryValidate.manifest_chain([partial], nil)
      assert {:error, _} = RecoveryValidate.manifest_chain([%{}], nil)
    end

    test "a partial SPAN body is refused, not raised", %{page: page} do
      # The same hole one level down: a struct-shaped page whose spans are bare maps.
      bad = %{page | classification_spans: [%{from_sequence: 1}]}

      assert {:error, :manifest_chain} = RecoveryValidate.manifest_chain([bad], nil)
    end

    test "a generated span carrying a NON-struct oneof body is refused, not raised", %{page: page} do
      # THE DEEPEST ARM. Outer struct guards let this through: the page is a real
      # EdgeLossManifestPageV1 and the span a real EdgeClassificationSpanV1, but the oneof
      # body is a bare map, so `b.identity` and `id.producer_assignment_id` would raise.
      span = hd(page.classification_spans)

      for body <- [
            {:attributed_active, %{}},
            {:attributed_passive, %{}},
            {:unattributable, %{}}
          ] do
        bad = %{page | classification_spans: [%{span | classification: body}]}

        assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([bad], nil),
               "a #{elem(body, 0)} body that is not its generated struct must REFUSE"
      end
    end

    test "a generated ACTIVE body carrying a non-struct IDENTITY is refused", %{page: page} do
      span = hd(page.classification_spans)
      body = %Serviceradar.Edge.V1.EdgeAttributedActiveV1{identity: %{}, range_sha256: <<0::256>>}
      bad = %{page | classification_spans: [%{span | classification: {:attributed_active, body}}]}

      assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([bad], nil)
    end

    test "a VALID identity carrying a non-struct SOURCE is refused", %{page: page} do
      # SEPARATE from the identity row: with a malformed identity the identity clause wins and
      # the source depth is never reached. Here the identity is the REAL one and only its
      # source is wrong, so this row is the only thing covering that depth.
      span = hd(page.classification_spans)
      {:attributed_active, act} = span.classification

      body = %{act | identity: %{act.identity | source: %{}}}
      bad = %{page | classification_spans: [%{span | classification: {:attributed_active, body}}]}

      assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([bad], nil)
    end

    test "invalid SCALAR domains are refused, not raised, at the level that owns them",
         %{page: page} do
      # The struct NAME is not the shape: every field is still `term()`, so these reach the
      # field-framed digest helpers and raise FunctionClauseError on `u64/1` or `bytes/1`
      # unless each field is checked against its GENERATED declared type.
      #
      # THE REASON IS PER LEVEL. A page scalar is a page fault; anything at or below the span
      # body is a body fault. Checking the page recursively would collapse the second into the
      # first and lose the distinction.
      span = hd(page.classification_spans)
      {:attributed_active, act} = span.classification
      id = act.identity

      put = fn body ->
        %{page | classification_spans: [%{span | classification: {:attributed_active, body}}]}
      end

      page_level = [
        {"terminal", %{page | terminal: :bad}},
        {"prev_page_sha256", %{page | prev_page_sha256: :bad}},
        {"span from_sequence", %{page | classification_spans: [%{span | from_sequence: :bad}]}}
      ]

      body_level = [
        {"run_shard", put.(%{act | identity: %{id | run_shard: :bad}})},
        {"authority_epoch", put.(%{act | identity: %{id | authority_epoch: :bad}})},
        {"range_sha256", put.(%{act | range_sha256: :bad})}
      ]

      for {name, bad} <- page_level do
        assert {:error, :manifest_chain} = RecoveryValidate.manifest_chain([bad], nil),
               "#{name} carries a term the wire cannot produce; expected a PAGE fault"
      end

      for {name, bad} <- body_level do
        assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([bad], nil),
               "#{name} carries a term the wire cannot produce; expected a BODY fault"
      end
    end

    test "a field holding the WRONG generated message type is refused", %{page: page} do
      # A shape check that asks "is this SOME generated struct" fails open: the substituted
      # message is wire-shaped, passes preflight, and then reaches a clause that matches only
      # the declared type -- raising exactly where the check promised a refusal.
      span = hd(page.classification_spans)
      {:attributed_active, act} = span.classification

      wrong = %EdgeUnattributableV1{reason: 1}
      body = %{act | identity: %{act.identity | source: wrong}}
      bad = %{page | classification_spans: [%{span | classification: {:attributed_active, body}}]}

      assert {:error, :manifest_span_body} = RecoveryValidate.manifest_chain([bad], nil)
    end

    test "a NEGATIVE value in an unsigned field is refused", %{page: page} do
      # `is_integer/1` is not the domain. `u64/1` frames -1 identically to the maximum uint64,
      # so a span with negative sequences reseals cleanly and two different spans share ONE
      # preimage -- the digest cannot tell them apart.
      #
      # WHAT THIS ROW PROVES, EXACTLY: the NEGATIVE arm. Removing the range check admits this
      # input, so the row is not vacuous. It does NOT pin the upper ends -- an oversized
      # `page_index` still meets the `page_index == i` relation and returns the same
      # `:manifest_chain`, and an upper-u64 sequence is UNPROVEN and out of scope here. Those
      # are impossible-state mutations; chasing them would expand the proof surface without
      # changing a reachable verdict.
      span = hd(page.classification_spans)

      negative = %{
        page
        | classification_spans: [%{span | from_sequence: -1, through_sequence: -1}]
      }

      assert {:error, :manifest_chain} = RecoveryValidate.manifest_chain([negative], nil)
    end

    test "an improper NESTED repeated field is refused by the production path", %{page: page} do
      span = hd(page.classification_spans)
      bad = %{page | classification_spans: [span | :tail]}

      # THE COUNT CEILING GETS THERE FIRST, and that is the honest verdict to assert:
      # `classification_spans` is the ONLY repeated field in the recovery subtree and it is
      # count-bounded, so the bounded walk reports it before any shape or unknown-field
      # traversal is entered.
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain([bad], nil)
    end

    # NO HELPER-ONLY IMPROPER-LIST ROW. `WireShape` and the unknown-field walker are both
    # proper-list-total, but `classification_spans` is the only repeated field in this subtree
    # and the count ceiling refuses an improper one first, so a row at the helper would prove a
    # property no production input reaches. The totality stays as defence for a future caller
    # that has no ceiling in front of it; it does not get proof surface it has not earned.

    test "the shape contract is DESCRIPTOR-decided, not value-decided" do
      # These two are contract defects, not recovery-admission ones, so they are asserted at
      # the helper: an EMPTY unsupported message and a nil enum both produce no offending
      # value to trip over, so a value-driven check passes them and a descriptor-driven one
      # does not. `%BatchGetRequest{keys: []}` passing while `keys: ["x"]` fails is a coin
      # flip on the input, not a contract.
      # `Google.Api.Expr.V1alpha1.Constant` is chosen for its SHAPE, not its meaning: every
      # field this module does not implement sits in a ONEOF, which is ABSENT by default, so a
      # default-constructed one offers NO offending value at all. A value-driven check passes
      # it and refuses the same message once a member is selected -- a coin flip on the input.
      # It was picked by MEASUREMENT: with the descriptor gate reverted, this is one of the
      # modules the value-driven design wrongly passes. Most messages hide the defect, because
      # an unsupported SINGULAR scalar still has a zero value to trip over.
      # The BEHAVIOURAL refusal is the whole proof; the closure needs no accessor to expose it,
      # and one existing only for this row would be API surface a test invented.
      outside = Google.Api.Expr.V1alpha1.Constant

      refute WireShape.wire_shaped?(struct(outside)),
             "an EMPTY struct outside the supported closure must still be refused"

      refute WireShape.wire_shaped?(%EdgeUnattributableV1{reason: nil}),
             "a nil enum is not a decoder output; the generic nil fallback must not reach it"

      assert WireShape.wire_shaped?(%EdgeUnattributableV1{
               reason: :EDGE_UNATTRIBUTABLE_REASON_UNSPECIFIED
             })
    end

    # NO ROWS FOR THE ENUM AND SELECTED-ONEOF-NIL ARMS. Both were written and both were
    # VACUOUS: `source.kind` holding a declared NUMBER is already refused by
    # `kind in @accepted_source_kinds` (which holds atoms), and `{:attributed_active, nil}` is
    # already refused by `span_body/1`'s catch-all. Reverting either WireShape arm leaves all
    # rows green, so a production control there would assert a verdict the semantic layer
    # produces anyway.
    #
    # The arms are still CORRECT and still worth having -- they fix concrete wrong answers in
    # the helper's own contract -- but for THIS graph they change no verdict, and a row that
    # passes with the code removed proves nothing about the code.

    test "BOUNDS beat the declared page count in the tombstone", %{page: page} do
      # THE PARITY CONTROL, and it needs a REAL over-ceiling list. An improper tail cannot
      # distinguish bounds-first from a chain error for :over -- both refuse -- so it proves
      # nothing about the order Go and this runtime now share.
      limits = RecoveryValidate.limits()
      over = List.duplicate(page, limits.max_manifest_pages + 1)

      t = %{
        recovery_id: page.recovery_id,
        prior_spool_id: uuidv7(0x11),
        new_spool_id: uuidv7(0x22),
        digest_version: 1,
        # DELIBERATELY DISAGREES, so a relation-first order would report a chain mismatch.
        manifest_page_count: 1,
        manifest_root_sha256: <<0::256>>,
        reason: "x",
        __unknown_fields__: []
      }

      assert {:error, :manifest_bounds} = RecoveryValidate.tombstone(t, over)
    end

    test "the three public recovery entrypoints refuse a non-list", %{page: page} do
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain(:nope, nil)
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain_from_raw(:nope, nil)
      assert {:error, :manifest_bounds} = RecoveryValidate.tombstone(%{}, :nope)
      _ = page
    end

    test "a page list exactly AT the ceiling is not refused for its count", %{page: page} do
      # INCLUSIVITY for the PAGE-LIST ceiling only. Without it, tightening that one check
      # from `<=` to `<` survives every test above, each of which proves only that one-over
      # is refused. It makes no claim about the per-page span ceiling, which needs its own
      # at-ceiling control.
      limits = RecoveryValidate.limits()
      at = List.duplicate(page, limits.max_manifest_pages)

      refute match?({:error, :manifest_bounds}, RecoveryValidate.manifest_chain(at, nil)),
             "a page list at exactly the ceiling was refused as a BOUNDS violation"
    end
  end

  describe "plan ceilings precede the unknown-field walk" do
    # The PLAN peer of the recovery block above. Without it, `PlanValidate.validate/2` could
    # have its ordering reverted and only Go would notice -- which is the shape of gap this
    # whole task exists to close.
    setup do
      %{header: plan_header(), page: plan_page()}
    end

    test "the page-list ceiling fires before the walk", %{header: h, page: page} do
      # ONLY THE LAST page's LAST range is tainted. Tainting every page would let the walk
      # stop on page one, which proves nothing about traversing an oversize list.
      over = List.duplicate(page, @max_pages) ++ [taint_range(page)]

      # RESEALED. A header whose page_count is changed without recomputing its digest is
      # refused as a stale DIGEST before any count runs, so an unsealed header would make
      # this row pass without reaching the ceiling it names.
      header = reseal_header(%{h | page_count: @max_pages + 1})

      assert {:error, :page_bounds} = PlanValidate.validate(header, over)
    end

    test "the per-page range ceiling fires before the walk", %{header: h, page: page} do
      range = hd(page.ranges)
      fat = taint_range(%{page | ranges: List.duplicate(range, @max_ranges + 1)})

      # A LEGAL page count, so the list ceiling cannot be what refuses this.
      assert {:error, :page_bounds} = PlanValidate.validate(h, [fat])
    end

    test "the unknown-field walk still precedes the SEMANTIC rules", %{header: h, page: page} do
      # Counts legal, so neither ceiling fires; the tainted page must still report the
      # unknown field rather than a later chain or digest rule.
      assert {:error, :unknown_fields} =
               PlanValidate.validate(h, [taint_range(%{page | page_index: 99})])
    end
  end

  describe "the bounded count is reached through every public call site" do
    # THE HELPER'S OWN TESTS ARE NOT ENOUGH. They prove BoundedList stops at cap+1; they say
    # nothing about whether a given production caller still uses it. Replacing ONE call with
    # `length/1` leaves every helper test green.
    #
    # The improper tail is what closes that: `length/1` RAISES ArgumentError on it, and every
    # function below promises `{:error, reason}`. So each row fails loudly the moment its own
    # call site regresses -- one row per independently removable site.

    test "PlanValidate.validate/2 page list" do
      # A REAL sealed header: a stub is refused for its identity before any count runs, which
      # would make this row pass without reaching the site it names.
      assert {:error, :page_bounds} = PlanValidate.validate(plan_header(), [plan_page() | :tail])
    end

    test "PlanValidate.validate/2 per-page range list" do
      page = plan_page()
      improper = %{page | ranges: [hd(page.ranges) | :tail]}

      assert {:error, :page_bounds} = PlanValidate.validate(plan_header(), [improper])
    end

    test "RecoveryValidate.manifest_chain/2 page list" do
      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain([:a | :tail], nil)
    end

    test "RecoveryValidate.manifest_chain/2 per-page span list" do
      page = go_page()
      improper = %{page | classification_spans: [hd(page.classification_spans) | :tail]}

      assert {:error, :manifest_bounds} = RecoveryValidate.manifest_chain([improper], nil)
    end

    test "RecoveryValidate.tombstone/2 page list" do
      page = go_page()

      # EVERY EARLIER RULE MUST PASS, or this row never reaches the count. An earlier
      # revision reused one uuid for both spool ids, so it exited on prior != new and proved
      # nothing about the site it names.
      t = %{
        recovery_id: page.recovery_id,
        prior_spool_id: uuidv7(0x11),
        new_spool_id: uuidv7(0x22),
        digest_version: 1,
        manifest_page_count: 1,
        manifest_root_sha256: <<0::256>>,
        reason: "x",
        __unknown_fields__: []
      }

      # THE EXACT fault: an improper page list is a BOUNDS refusal, not a chain mismatch and
      # not a raise. `length/1` here would raise ArgumentError.
      assert {:error, :manifest_bounds} = RecoveryValidate.tombstone(t, [page | :tail])
    end

    # THE SWEEP HOST SITE IS NOT DUPLICATED HERE. `sweep_body_validate_test.exs` already
    # covers it against a VALID batch -- and covers it better, with both an over-cap arm and
    # an under-cap arm proving the pair is not vacuous. A row here would need that fixture
    # anyway (a bare struct is refused for its UNSPECIFIED source long before the host
    # ceiling), so it would be a worse copy of a test that exists.

    test "AssignmentValidate raw plan page list" do
      # The RAW assignment path -- bound_page_count/2 -- which the decoded rows above never
      # reach. One row per independently removable site; this is one of eight.
      assert {:error, :page_bounds} =
               AssignmentValidate.validate_bytes_against_plan_bytes(
                 <<>>,
                 plan_header_bytes(),
                 [plan_page_bytes() | :tail]
               )
    end

    test "RecoveryValidate raw manifest page list" do
      # The RAW recovery path -- bound_received/1 -- which the decoded rows do not reach.
      assert {:error, :manifest_bounds} =
               RecoveryValidate.manifest_chain_from_raw([plan_page_bytes() | :tail], nil)
    end
  end

  # The taint goes on the LAST nested SPAN, not on the page. A page-level unknown field is
  # found before `no_unknown_fields?/1` descends anywhere, so it would prove only that the
  # top-level check runs first; on the final span the walk must traverse every child to reach
  # it -- the traversal the count ceiling is supposed to prevent.
  defp taint(page) do
    spans = page.classification_spans
    {init, [last]} = Enum.split(spans, -1)
    tainted = %{last | __unknown_fields__: [{60_000, 0, <<0>>}]}
    %{page | classification_spans: init ++ [tainted]}
  end

  # The taint sits on the LAST RANGE, so the walk must descend through every range to find it.
  defp taint_range(page) do
    {init, [last]} = Enum.split(page.ranges, -1)
    %{page | ranges: init ++ [%{last | __unknown_fields__: [{60_000, 0, <<0>>}]}]}
  end

  # A canonical UUIDv7: version nibble 7, variant bits 10. Built rather than imported so this
  # suite does not depend on another test module's private helpers.
  defp uuidv7(seed) do
    <<a::48, _::4, b::12, _::2, c::62>> = :binary.copy(<<seed>>, 16)
    <<a::48, 7::4, b::12, 2::2, c::62>>
  end

  defp plan_header_bytes, do: read_fixture("plan_header.bin")
  defp plan_page_bytes, do: read_fixture("plan_page.bin")

  defp read_fixture(name), do: fixture_dir() |> Path.join(name) |> File.read!()

  defp reseal_header(h),
    do: %{h | execution_plan_sha256: ServiceRadar.Edge.HashGrammar.plan_header_digest(h)}

  defp plan_header,
    do: decode_fixture("plan_header.bin", Serviceradar.Edge.V1.ScheduledPlanHeaderV1)

  defp plan_page, do: decode_fixture("plan_page.bin", Serviceradar.Edge.V1.ScheduledPlanPageV1)

  defp decode_fixture(name, mod) do
    fixture_dir()
    |> Path.join(name)
    |> File.read!()
    |> mod.decode()
  end

  defp go_page,
    do: decode_fixture("manifest_page.bin", Serviceradar.Edge.V1.EdgeLossManifestPageV1)

  # The SAME committed fixtures the recovery and golden suites already read, resolved the same
  # way. Locally-constructed pages would let this suite disagree with those about what a page is.
  defp fixture_dir do
    dir =
      [
        Path.expand("../../../../../proto/edge/v1/testdata", __DIR__),
        System.get_env("TEST_SRCDIR") &&
          Path.join([System.get_env("TEST_SRCDIR"), "_main", "proto/edge/v1/testdata"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.dir?/1)

    if !dir, do: flunk("shared fixture directory not found")
    dir
  end
end
