defmodule ServiceRadar.Edge.PresenceCorpusTest do
  @moduledoc """
  The SHARED OPTIONAL-PRESENCE corpus (task 1.5-d): absent versus present-zero, for every
  explicitly optional scalar in the edge ABI.

  Go writes one control per carrier with every optional scalar PRESENT-ZERO, and one variant per
  FIELD omitting exactly that field. Each manifest row is therefore a single-axis comparison: a
  pair that toggled a carrier's optionals together could not tell a field that became
  presence-required from siblings that stayed indifferent.

  Fifteen of the eighteen are MEASUREMENTS, where absent means "not measured". The other three --
  `authority_epoch`, `plan_ordinal_offset`, `mtr_ordinal_count` -- are required authority and
  window statements, optional in the schema so absent is distinguishable from zero rather than so
  they may be omitted.

  ## What this runtime claims, per carrier, and why they differ

  Two carriers have NO Elixir admission boundary. There is no record validator and no MTR batch
  validator here -- `SemanticValidate` polices enums, not shape -- so for `EdgeProducerContext`
  and `MtrTraceHopV1` this suite claims only what it can see without one:

    * the two encodings are DIFFERENT BYTES,
    * decoded presence differs, and differs ONLY in the field the row names,
    * a present value is EXACTLY ZERO, not merely truthy.

  It does NOT claim an accept/refuse verdict for them. Writing an Elixir check to manufacture one
  would prove that a test can refuse its own inputs and nothing about what this runtime admits.
  The manifest records which carriers get which treatment, so the weaker claim is visible in the
  data rather than buried here.

  For the other six carriers the real validators run -- `SweepBodyValidate`, `AssignmentValidate`,
  `PlanValidate` -- and must reach the SAME accept/refuse verdict Go recorded.

  ## The inventory is descriptor-derived on BOTH sides

  Go walks its generated descriptors for synthetic-oneof scalars; this suite walks
  `__message_props__` for `proto3_optional?`. The two are compared against the shared manifest in
  both directions, so a new optional field added to any edge message fails here as well.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AssignmentValidate
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SweepBodyValidate
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @manifest Path.join(@testdata, "presence_corpus.txt")
  @external_resource @manifest

  defp testdata_dir do
    cond do
      File.dir?(@testdata) ->
        @testdata

      dir = System.get_env("TEST_SRCDIR") ->
        [System.get_env("TEST_WORKSPACE"), "_main"]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Path.join([dir, &1, "proto/edge/v1/testdata"]))
        |> Enum.find(&File.dir?/1)
        |> case do
          nil -> flunk("shared fixture directory not found under #{@testdata} or TEST_SRCDIR")
          p -> p
        end

      true ->
        flunk("shared fixture directory not found under #{@testdata}")
    end
  end

  defp load(name), do: testdata_dir() |> Path.join(name) |> File.read!()

  defp rows do
    testdata_dir()
    |> Path.join("presence_corpus.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      [field, carrier, control, variant, peer_file, policy, peer] = String.split(line)

      %{
        field: field,
        carrier: carrier,
        control: control,
        variant: variant,
        peer_file: peer_file,
        policy: policy,
        peer: peer,
        name: field |> String.split(".") |> List.last()
      }
    end)
  end

  # ---- the descriptor walk, this runtime's half of the pinned inventory -------------------

  # protobuf-elixir marks an explicit proto3 `optional` scalar with proto3_optional? on its field
  # props. Enumerating them is what keeps this suite's coverage tied to the SCHEMA rather than to
  # a hand-written list that silently falls behind it.
  defp descriptor_optional_scalars do
    # `:code.all_available/0`, NOT `:application.get_key(:modules)`. The Bazel shard runs the
    # test files with `elixir -r` and never loads the application, so get_key returns nothing
    # there -- the walk came back EMPTY and the descriptor-to-manifest direction passed
    # vacuously while only the reverse direction failed. Code-path enumeration does not depend
    # on an application being loaded.
    # Filter the CHARLIST first and atomize only the generated edge modules. Atomizing every
    # module on the code path to then discard almost all of them creates atoms for the entire
    # release, and atoms are never garbage collected.
    :code.all_available()
    |> Enum.filter(fn {name, _path, _loaded} ->
      List.starts_with?(name, ~c"Elixir.Serviceradar.Edge.V1.")
    end)
    |> Enum.map(fn {name, _path, _loaded} -> List.to_atom(name) end)
    |> Enum.filter(fn m ->
      Code.ensure_loaded?(m) and function_exported?(m, :__message_props__, 0)
    end)
    |> Enum.flat_map(fn m ->
      props = m.__message_props__()

      if Map.get(props, :enum?) do
        []
      else
        carrier = m |> Module.split() |> List.last()

        props.field_props
        |> Map.values()
        |> Enum.filter(fn fp ->
          Map.get(fp, :proto3_optional?) and Map.get(fp, :embedded?) != true
        end)
        |> Enum.map(fn fp -> {"#{carrier}.#{fp.name}", carrier} end)
      end
    end)
    |> Map.new()
  end

  # ---- presence, read off the decoded struct ----------------------------------------------

  defp decode(carrier, bytes) do
    case carrier do
      "EdgeProducerContext" -> EdgeRecordV1.decode(bytes)
      "MtrTraceHopV1" -> MtrTraceBatchV1.decode(bytes)
      "SweepMtrExpectationV1" -> SweepAssignmentRecordV1.decode(bytes)
      "TargetRangeV1" -> ScheduledPlanPageV1.decode(bytes)
      _ -> SweepObservationBatchV1.decode(bytes)
    end
  end

  # Walks to the FIRST instance of the carrier and returns its optional scalars as
  # %{name => value | nil}. Reflective for the same reason Go's is: a hand-written extractor is a
  # second copy of the inventory, and it drifts.
  defp optional_scalars(struct, carrier) do
    struct
    |> find_carrier(carrier)
    |> case do
      nil ->
        flunk("carrier #{carrier} not found in the decoded artifact")

      m ->
        props = m.__struct__.__message_props__()

        props.field_props
        |> Map.values()
        |> Enum.filter(&Map.get(&1, :proto3_optional?))
        |> Map.new(fn fp -> {Atom.to_string(fp.name_atom), Map.get(m, fp.name_atom)} end)
    end
  end

  defp find_carrier(%_{} = m, carrier) do
    if m.__struct__ |> Module.split() |> List.last() == carrier do
      m
    else
      m
      |> Map.from_struct()
      |> Enum.find_value(fn {_k, v} -> find_carrier(v, carrier) end)
    end
  end

  defp find_carrier(list, carrier) when is_list(list),
    do: Enum.find_value(list, &find_carrier(&1, carrier))

  defp find_carrier({_tag, v}, carrier), do: find_carrier(v, carrier)
  defp find_carrier(_other, _carrier), do: nil

  # ---- the production validators, where this runtime has one ------------------------------

  defp validate("SweepMtrExpectationV1", struct), do: AssignmentValidate.validate(struct)

  defp validate("TargetRangeV1", struct) do
    header_file =
      rows() |> Enum.find(&(&1.carrier == "TargetRangeV1")) |> Map.fetch!(:peer_file)

    PlanValidate.validate(plan_header(struct, header_file), [struct])
  end

  defp validate(_sweep_carrier, struct), do: SweepBodyValidate.validate(struct)

  # The header is rebuilt over whatever page arrives, EXCEPT its MTR commitment, which is
  # carried by the COMMITTED header artifact -- so an absent mtr_ordinal_count is refused by the
  # validator reaching its own window check, not by a header this suite could not construct.
  defp plan_header(page, header_file) do
    header = ScheduledPlanHeaderV1.decode(load(header_file))

    rerooted = %{
      header
      | page_count: 1,
        total_target_count: Enum.reduce(page.ranges, 0, &(&1.target_count + &2)),
        plan_root_sha256: HashGrammar.plan_root([page])
    }

    %{rerooted | execution_plan_sha256: HashGrammar.plan_header_digest(rerooted)}
  end

  defp accepted?(:ok), do: true
  defp accepted?({:ok, _}), do: true
  defp accepted?(_), do: false

  # ---- the gates ---------------------------------------------------------------------------

  test "the manifest and this runtime's descriptors name the same optional scalars" do
    from_descriptor = descriptor_optional_scalars()
    from_manifest = Map.new(rows(), &{&1.field, &1.carrier})

    # NON-VACUITY FIRST. An empty walk satisfies the descriptor-to-manifest direction for free,
    # which is exactly how this test passed under `mix test` while finding nothing under Bazel.
    refute Enum.empty?(from_descriptor),
           "the descriptor walk found NO optional scalars; the comparison below would be vacuous"

    assert map_size(from_descriptor) == map_size(from_manifest)

    for {field, carrier} <- from_descriptor do
      assert Map.has_key?(from_manifest, field),
             "#{field} is optional in this runtime's descriptors but has no manifest row"

      assert from_manifest[field] == carrier,
             "#{field}: manifest carrier #{from_manifest[field]}, descriptor says #{carrier}"
    end

    for {field, _carrier} <- from_manifest do
      assert Map.has_key?(from_descriptor, field),
             "the manifest names #{field}, which is not optional in this runtime's descriptors"
    end
  end

  test "absent and present-zero are DIFFERENT BYTES, for every row" do
    for row <- rows() do
      refute load(row.control) == load(row.variant),
             "#{row.field}: the two encodings are identical bytes, so the row varies nothing"
    end
  end

  test "presence differs only in the field the row names, and a present value is exactly zero" do
    for row <- rows() do
      control = row.carrier |> decode(load(row.control)) |> optional_scalars(row.carrier)
      variant = row.carrier |> decode(load(row.variant)) |> optional_scalars(row.carrier)

      assert control[row.name] == 0,
             "#{row.field}: the control must carry it PRESENT and EXACTLY ZERO, got " <>
               inspect(control[row.name])

      assert variant[row.name] == nil,
             "#{row.field}: the variant must OMIT it, got #{inspect(variant[row.name])}"

      for {name, value} <- control, name != row.name do
        assert variant[name] == value,
               "#{row.field}: the variant also changed #{name} " <>
                 "(#{inspect(value)} -> #{inspect(variant[name])})"
      end
    end
  end

  test "where this runtime HAS a validator, it reaches the verdict Go recorded" do
    enforced = Enum.filter(rows(), &(&1.peer == "validator"))

    assert length(enforced) == 9

    for row <- enforced do
      control = decode(row.carrier, load(row.control))
      variant = decode(row.carrier, load(row.variant))

      assert accepted?(validate(row.carrier, control)),
             "#{row.field}: the all-present-zero control was refused"

      case row.policy do
        "required" ->
          refute accepted?(validate(row.carrier, variant)),
                 "#{row.field}: Go refuses this absence; this runtime admitted it"

        "indifferent" ->
          assert accepted?(validate(row.carrier, variant)),
                 "#{row.field}: Go admits this absence; this runtime refused it"
      end
    end
  end

  test "the manifest and the fixtures ON DISK agree in both directions" do
    listed =
      rows()
      |> Enum.flat_map(&[&1.control, &1.variant, &1.peer_file])
      |> Enum.reject(&(&1 == "-"))
      |> MapSet.new()

    on_disk =
      testdata_dir()
      |> Path.join("presence_*.bin")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    refute Enum.empty?(on_disk), "no presence_*.bin staged; this guard would pass vacuously"

    assert listed |> MapSet.difference(on_disk) |> Enum.to_list() == [],
           "the manifest names files that are not on disk"

    assert on_disk |> MapSet.difference(listed) |> Enum.to_list() == [],
           "fixtures are on disk that no manifest row names, so no runtime reads them"
  end

  test "the carriers with NO Elixir boundary are named, not silently skipped" do
    observation = rows() |> Enum.filter(&(&1.peer == "observation")) |> MapSet.new(& &1.carrier)

    assert observation == MapSet.new(["EdgeProducerContext", "MtrTraceHopV1"]),
           "the set of carriers without an Elixir admission boundary moved; gaining or losing " <>
             "one is a contract change, not bookkeeping"
  end
end
