# Deliberately absent from @enum_field_policy: proves an unpoliced enum field fails CLOSED.
defmodule UnpolicedEnumFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:state, 1, type: Serviceradar.Edge.V1.EdgeRecordTrafficClass, enum: true)
end

# Self-referential message for the depth boundary proof.
defmodule RecursiveSemanticFixture do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:next, 1, type: RecursiveSemanticFixture)
end

# Metadata shapes the walk does not expect. Each must be CONTAINED as a typed readiness outcome
# rather than escaping as a raw exception.
defmodule BrokenSemanticProps do
  @moduledoc false
  defstruct [:x]

  # FieldProps missing every key the walk reads (enum?/embedded?/oneof/repeated?).
  def __message_props__, do: %{field_props: %{1 => %{name_atom: :x}}, oneof: []}
end

defmodule BrokenOneofProps do
  @moduledoc false
  defstruct [:x]

  # A field claiming oneof index 3 with no matching oneof entry.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{name_atom: :x, enum?: false, embedded?: false, repeated?: false, oneof: 3}
      },
      oneof: []
    }
  end
end

# `Enum.at/2` accepts NEGATIVE indexes and a loose `{name, _}` match ignores the declared index, so
# both of these previously resolved to some entry and SKIPPED the field (fail-open).
defmodule NegativeOneofIndexProps do
  @moduledoc false
  defstruct [:choice]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{name_atom: :a, enum?: false, embedded?: false, repeated?: false, oneof: -1}
      },
      oneof: [{:choice, 0}]
    }
  end
end

defmodule MismatchedOneofIndexProps do
  @moduledoc false
  defstruct [:choice]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{name_atom: :a, enum?: false, embedded?: false, repeated?: false, oneof: 0}
      },
      oneof: [{:choice, 99}]
    }
  end
end

# Malformed metadata that does NOT raise: the rescue/catch boundary cannot help here, so the shape
# has to be validated explicitly or the field is silently skipped.
defmodule ShapelessFieldProps do
  @moduledoc false
  defstruct [:x]

  # Missing enum?/embedded?/repeated?/type: every typed clause misses and the catch-all skips it.
  def __message_props__, do: %{field_props: %{1 => %{name_atom: :x, oneof: nil}}, oneof: []}
end

defmodule WrongOneofStorageProps do
  @moduledoc false
  defstruct [:choice]

  # The oneof index pins correctly, but the declared STORAGE key does not exist on the struct, so
  # Map.get/2 returns nil and a set member reads as "inactive".
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :state,
          enum?: true,
          embedded?: false,
          repeated?: false,
          oneof: 0,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: [{:wrong_choice, 0}]
    }
  end
end

# The four NON-RAISING drift shapes from the consolidated finding, plus the orphan-oneof gap. Each
# previously returned :ok, silently skipping a retained non-member enum.
defmodule MissingOrdinaryStorageProps do
  @moduledoc false
  defstruct [:present]

  # (1) An otherwise shape-valid ORDINARY enum field naming a storage key absent from the struct.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :ghost,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule IncoherentFlagsProps do
  @moduledoc false
  defstruct [:x]

  # (2) An enum TYPE with enum? = false: the dispatch flags disagree with the type.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :x,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule NonBooleanMapFlagProps do
  @moduledoc false
  defstruct [:m]

  # (3) An embedded enum-valued map whose `map?` is not a boolean: the map clause never matches.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: nil,
          oneof: nil,
          type: Serviceradar.Edge.V1.EdgeRecordV1
        }
      },
      oneof: []
    }
  end
end

defmodule BadMapEntryValueProps do
  @moduledoc false
  defstruct [:m]

  # (4) A map whose ENTRY value metadata misreports enum?, so map_value_field/1 calls it a scalar.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: BadMapEntry
        }
      },
      oneof: []
    }
  end
end

defmodule BadMapEntry do
  @moduledoc false
  defstruct [:key, :value]

  def __message_props__ do
    %{
      field_props: %{
        2 => %{
          name_atom: :value,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule OrphanOneofProps do
  @moduledoc false
  defstruct [:choice]

  # A declared oneof entry with NO member field: validation iterates field_props, so a populated
  # orphan oneof would never be inspected at all.
  def __message_props__, do: %{field_props: %{}, oneof: [{:choice, 0}]}
end

# Graph-congruence probes: each is a schema/readiness failure, not a valid record.
defmodule UndescribedStorageProps do
  @moduledoc false
  # (1) A struct key no metadata describes -- never visited, so a retained value there is never seen.
  defstruct hidden: -1
  def __message_props__, do: %{field_props: %{}, oneof: []}
end

defmodule UnloadableEnumProps do
  @moduledoc false
  defstruct [:x]

  # (2) The declared ENUM module does not exist.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :x,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, NoSuchEnumModule}
        }
      },
      oneof: []
    }
  end
end

defmodule UnloadableChildProps do
  @moduledoc false
  defstruct [:child]

  # (3) The declared embedded CHILD schema does not exist.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :child,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: NoSuchChildModule
        }
      },
      oneof: []
    }
  end
end

defmodule BadEntryStorage do
  @moduledoc false
  # (4) The Entry's tag-2 metadata names storage absent from the Entry struct.
  defstruct [:key]

  def __message_props__ do
    %{
      field_props: %{
        2 => %{
          name_atom: :value,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule BadEntryStorageMap do
  @moduledoc false
  defstruct [:m]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: BadEntryStorage
        }
      },
      oneof: []
    }
  end
end

defmodule TypedChild do
  @moduledoc false
  defstruct [:v]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :v,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule UntypedOneofValueProps do
  @moduledoc false
  defstruct [:choice]

  # (5) A SELECTED embedded oneof value that is not the declared child struct.
  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :child,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: false,
          oneof: 0,
          type: TypedChild
        }
      },
      oneof: [{:choice, 0}]
    }
  end
end

# A map Entry whose tag-2 value points BACK at itself with map?: true. Protobuf forbids a map of
# maps; without rejecting that, congruence recurses forever and no rescue/catch can contain it.
defmodule CyclicMapEntry do
  @moduledoc false
  defstruct [:key, :value]

  def __message_props__ do
    %{
      field_props: %{
        2 => %{
          name_atom: :value,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: CyclicMapEntry
        }
      },
      oneof: []
    }
  end
end

defmodule CyclicMapProps do
  @moduledoc false
  defstruct [:m]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: CyclicMapEntry
        }
      },
      oneof: []
    }
  end
end

# Container-shape probes. Cardinality is part of the schema contract: a wrong-shaped container is a
# readiness defect, not a value to interpret.
defmodule ShapeKid do
  @moduledoc false
  defstruct [:v]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :v,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: :int32
        }
      },
      oneof: []
    }
  end
end

defmodule RepeatedEmbeddedProps do
  @moduledoc false
  defstruct [:kids]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :kids,
          enum?: false,
          embedded?: true,
          repeated?: true,
          map?: false,
          oneof: nil,
          type: ShapeKid
        }
      },
      oneof: []
    }
  end
end

defmodule RepeatedEnumProps do
  @moduledoc false
  defstruct [:tags]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :tags,
          enum?: true,
          embedded?: false,
          repeated?: true,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

# An ORDINARY message with key/value fields is not a protobuf map Entry: it lacks the message-level
# `map?: true` marker generated code carries.
defmodule NotAMapEntry do
  @moduledoc false
  defstruct [:key, :value]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :key,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: :string
        },
        2 => %{
          name_atom: :value,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      },
      oneof: []
    }
  end
end

defmodule FakeMapProps do
  @moduledoc false
  defstruct [:m]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: NotAMapEntry
        }
      },
      oneof: []
    }
  end
end

# A canonical-LOOKING map Entry whose tag-2 FieldProps are internally incoherent: the value declares
# an enum TYPE but `enum?: false`. The Entry shell (map? marker, tags 1/2, legal key, non-map value)
# all pass, so only running the Entry through full local congruence catches it.
defmodule IncoherentEntryValue do
  @moduledoc false
  defstruct [:key, :value]

  def __message_props__ do
    %{
      map?: true,
      oneof: [],
      field_props: %{
        1 => %{
          name_atom: :key,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: :string
        },
        2 => %{
          name_atom: :value,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
        }
      }
    }
  end
end

defmodule IncoherentEntryHolder do
  @moduledoc false
  defstruct [:m]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: IncoherentEntryValue
        }
      },
      oneof: []
    }
  end
end

# Holder -> canonical map Entry -> enum module that is initially UNAVAILABLE. The holder's
# dependency fingerprint covers only its DIRECT Entry module, so a readiness failure that depends on
# this GRANDCHILD must not be cached under the holder's key.
defmodule GrandchildEntry do
  @moduledoc false
  defstruct [:key, :value]

  def __message_props__ do
    %{
      map?: true,
      oneof: [],
      field_props: %{
        1 => %{
          name_atom: :key,
          enum?: false,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: :string
        },
        2 => %{
          name_atom: :value,
          enum?: true,
          embedded?: false,
          repeated?: false,
          map?: false,
          oneof: nil,
          type: {:enum, LateLoadedMapEnum}
        }
      }
    }
  end
end

defmodule GrandchildHolder do
  @moduledoc false
  defstruct [:m]

  def __message_props__ do
    %{
      field_props: %{
        1 => %{
          name_atom: :m,
          enum?: false,
          embedded?: true,
          repeated?: false,
          map?: true,
          oneof: nil,
          type: GrandchildEntry
        }
      },
      oneof: []
    }
  end
end

defmodule RaisingSemanticProps do
  @moduledoc false
  defstruct [:x]
  def __message_props__, do: raise("boom")
end

defmodule ThrowingSemanticProps do
  @moduledoc false
  defstruct [:x]
  def __message_props__, do: throw(:boom)
end

defmodule ExitingSemanticProps do
  @moduledoc false
  defstruct [:x]
  def __message_props__, do: exit(:boom)
end

defmodule Serviceradar.Edge.SemanticValidateTest do
  @moduledoc """
  Task 1.5 enum parity, layer 2. Proves the FULL two-layer mechanism end to end:

    1. the patched generated edge enums RETAIN an unknown/negative int32 exactly as Go does, so
       protobuf's LAST-ONE-WINS resolution works and `-1` followed by a valid value is ACCEPTED; and
    2. `SemanticValidate` then rejects a RETAINED non-member -- ANYWHERE in the decoded graph, not
       just at the handful of fields with a field-specific rule -- so it can never be silently
       admitted, with the STAGE-correct disposition.

  The acceptance and known-slot proofs are built on the REAL golden fixtures (a complete lane-open
  carrying its UUIDv7 spool, sequence state, nonce and credits; a real delivery frame carrying
  recoverable spool/sequence coordinates), not on hand-rolled fragments that Go would reject for
  unrelated reasons.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1
  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias Serviceradar.Edge.V1.EdgeRecordLaneOpen
  alias Serviceradar.Edge.V1.EdgeRecordServerMessage
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.SweepExecutionEventV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Edge.WireDecode

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  defp load(name), do: File.read!(Path.join(@testdata, name))
  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<(n &&& 0x7F) ||| 0x80>> <> varint(n >>> 7)
  defp len_delim(tag, payload), do: <<tag>> <> varint(byte_size(payload)) <> payload

  # A negative int32 enum on the wire is the 10-byte two's-complement varint.
  defp negative_enum_field(tag_byte), do: <<tag_byte>> <> varint((1 <<< 64) - 1)

  # The RAW lane_open bytes of the golden client message (field 1, wire 2).
  defp golden_lane_open_bytes do
    <<0x0A, _len, rest::binary>> = load("client_lane_open.bin")
    rest
  end

  # Walks the real schemas collecting {module, field} for every reachable enum field.
  defp collect_enum_fields(mod, {acc, seen}) do
    if MapSet.member?(seen, mod) do
      {acc, seen}
    else
      seen = MapSet.put(seen, mod)
      %{field_props: fps} = mod.__message_props__()

      Enum.reduce(Map.values(fps), {acc, seen}, fn fp, {acc, seen} ->
        cond do
          fp.enum? -> {[{mod, fp.name_atom} | acc], seen}
          fp.embedded? and is_atom(fp.type) -> collect_enum_fields(fp.type, {acc, seen})
          true -> {acc, seen}
        end
      end)
    end
  end

  describe "PROOF 1: last-one-wins on the REAL golden lane -- earlier negative, later valid" do
    test "the Go-authored negative-then-valid lane vector is ACCEPTED here too" do
      # proto/edge/v1/golden_test.go writes these exact bytes and asserts Go decodes the effective
      # traffic_class as BULK and that ValidateLaneOpen returns nil. Both runtimes must agree; before
      # the enum-retention transform Elixir raised on the first (negative) occurrence and rejected a
      # lane Go accepts. Every field Go's ValidateLaneOpen requires (UUIDv7 spool, sequence_base,
      # first_unresolved_sequence, nonce, credits) is present because the vector is the REAL golden
      # lane with one extra earlier occurrence.
      assert {:ok, %EdgeRecordClientMessage{payload: {:lane_open, open}}} =
               WireDecode.decode_client_message(load("lane_open_negative_then_valid.bin"))

      assert open.traffic_class == :EDGE_RECORD_TRAFFIC_CLASS_BULK
      assert open.route_profile == :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
      assert byte_size(open.spool_id) == 16
      assert open.sequence_base == 1
      assert byte_size(open.session_nonce) > 0

      assert :ok = SemanticValidate.validate_lane_open(open)
      assert :ok = SemanticValidate.disposition(:ok, :lane_open)
    end

    test "the unmodified golden lane is accepted (control)" do
      {:ok, %{payload: {:lane_open, open}}} =
        WireDecode.decode_client_message(load("client_lane_open.bin"))

      assert :ok = SemanticValidate.validate_lane_open(open)
    end
  end

  describe "PROOF 2/3: a RETAINED non-member decodes, then is PERMANENTLY rejected" do
    test "a lone NEGATIVE traffic_class on the golden lane decodes retained and is rejected" do
      # Appending makes the negative the LAST occurrence, so it is the effective value.
      lane = golden_lane_open_bytes() <> negative_enum_field(0x10)

      assert {:ok, %EdgeRecordClientMessage{payload: {:lane_open, open}}} =
               WireDecode.decode_client_message(len_delim(0x0A, lane))

      # Retained as the raw integer, exactly as Go retains it (no raise, no quarantine).
      assert open.traffic_class == -1

      assert {:error, {:unsupported_enum, [:traffic_class]}} =
               SemanticValidate.validate_lane_open(open)
    end

    test "an UNKNOWN POSITIVE enum decodes retained and is rejected" do
      lane = golden_lane_open_bytes() <> <<0x10, 99>>

      {:ok, %{payload: {:lane_open, open}}} =
        WireDecode.decode_client_message(len_delim(0x0A, lane))

      assert open.traffic_class == 99

      assert {:error, {:unsupported_enum, [:traffic_class]}} =
               SemanticValidate.validate_lane_open(open)
    end

    test "UNSPECIFIED is rejected too, matching Go's known* sets which exclude it" do
      lane = golden_lane_open_bytes() <> <<0x10, 0>>

      {:ok, %{payload: {:lane_open, open}}} =
        WireDecode.decode_client_message(len_delim(0x0A, lane))

      assert {:error, {:unsupported_enum, [:traffic_class]}} =
               SemanticValidate.validate_lane_open(open)
    end
  end

  describe "PROOF: the retained-value gate covers EVERY patched enum, at every depth" do
    setup do
      %{record: EdgeRecordV1.decode(load("record.bin"))}
    end

    test "the valid record passes (control)", %{record: record} do
      assert :ok = SemanticValidate.validate_record(record)
    end

    # These are exactly the fields that slipped through a field-specific-only validator: the
    # transform makes EVERY edge enum retainable (the pinned inventory in
    # scripts/patch_edge_enum_negatives.exs, not a fixed count), so the gate must cover the
    # whole graph.
    test "a negative COMPRESSION is rejected", %{record: record} do
      assert {:error, {:unsupported_enum, [:compression]}} =
               SemanticValidate.validate_record(%{record | compression: -1})
    end

    test "a negative nested producer_context.ORIGIN_KIND is rejected", %{record: record} do
      bad = put_in(record.producer_context.origin_kind, -1)

      assert {:error, {:unsupported_enum, [:producer_context, :origin_kind]}} =
               SemanticValidate.validate_record(bad)
    end

    test "a negative enum inside the production CLAIMS oneof is rejected", %{record: record} do
      {:production, prod} = record.production_capability.claims
      claims = {:production, %{prod | traffic_class: -1}}
      bad = %{record | production_capability: %{record.production_capability | claims: claims}}

      assert {:error, {:unsupported_enum, path}} = SemanticValidate.validate_record(bad)
      assert :production_capability in path
      assert :traffic_class in path
    end

    test "a negative enum inside the source-authorization capability is rejected", %{
      record: record
    } do
      cap = record.source_authorization.capability
      {:source, src} = cap.claims
      bad_cap = %{cap | claims: {:source, %{src | kind: -1}}}
      sa = %{record.source_authorization | capability: bad_cap}

      assert {:error, {:unsupported_enum, path}} =
               SemanticValidate.validate_record(%{record | source_authorization: sa})

      assert :source_authorization in path
    end

    test "the OUTER source-authorization kind is still checked by its field-specific set",
         %{record: record} do
      sa = %{record.source_authorization | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED}

      assert {:error, {:unsupported_enum, [:source_authorization, :kind]}} =
               SemanticValidate.validate_record(%{record | source_authorization: sa})
    end

    test "validate_message/1 gates ANY decoded edge struct, for domain messages with no own rule" do
      assert :ok = SemanticValidate.validate_message(EdgeRecordV1.decode(load("record.bin")))

      frame = EdgeDeliveryFrameV1.decode(load("delivery_frame.bin"))
      assert :ok = SemanticValidate.validate_message(frame)
    end
  end

  describe "PROOF 4/5: dispositions are STAGE-specific" do
    test "a LANE-OPEN failure closes the handshake with NO disposition" do
      lane = golden_lane_open_bytes() <> negative_enum_field(0x10)

      {:ok, %{payload: {:lane_open, open}}} =
        WireDecode.decode_client_message(len_delim(0x0A, lane))

      outcome = SemanticValidate.validate_lane_open(open)

      # The handshake has no spool/sequence PAIRED WITH A DELIVERY, so there is no per-delivery slot
      # to resolve: close the lane and emit NO EdgeDeliveryAckV1 disposition of any kind.
      assert {:close_lane, {:unsupported_enum, [:traffic_class]}} =
               SemanticValidate.disposition(outcome, :lane_open)
    end

    test "a failure at a REAL delivery slot resolves REJECTED_PERMANENT" do
      # A FRESH delivery frame carries NO delivery capability, so there is no signed delivery claim
      # binding a record hash -- mutating record_bytes under a granted frame would invalidate
      # `delivery.record_sha256` and Go would reject the frame at the claim binding BEFORE the inner
      # enum verdict, which would make this proof meaningless.
      record = EdgeRecordV1.decode(load("record.bin"))

      bad_record =
        EdgeRecordV1.encode(%{record | compression: :EDGE_RECORD_COMPRESSION_UNSPECIFIED})

      golden_frame = EdgeDeliveryFrameV1.decode(load("delivery_frame.bin"))

      raw_frame =
        EdgeDeliveryFrameV1.encode(%EdgeDeliveryFrameV1{
          spool_id: golden_frame.spool_id,
          sequence: golden_frame.sequence,
          record_sha256: :crypto.hash(:sha256, bad_record),
          record_bytes: bad_record
        })

      # The OUTER frame is internally consistent and its slot coordinates are RECOVERABLE -- that is
      # what makes this a known slot rather than a pre-slot transport failure.
      assert {:ok, %EdgeDeliveryFrameV1{} = decoded} = WireDecode.decode_frame(raw_frame)
      assert decoded.delivery_capability == nil
      assert byte_size(decoded.spool_id) == 16
      assert decoded.sequence > 0
      assert :crypto.hash(:sha256, decoded.record_bytes) == decoded.record_sha256

      # The inner record decodes cleanly; only the SEMANTIC layer rejects it.
      assert {:ok, %EdgeRecordV1{} = inner} = WireDecode.decode_record(decoded.record_bytes)
      assert inner.compression == :EDGE_RECORD_COMPRESSION_UNSPECIFIED

      outcome = SemanticValidate.validate_record(inner)
      assert {:error, {:unsupported_enum, [:compression]}} = outcome

      assert {:disposition, :REJECTED_PERMANENT, {:unsupported_enum, [:compression]}} =
               SemanticValidate.disposition(outcome, :delivery)
    end
  end

  describe "policy coverage is EXHAUSTIVE by construction" do
    test "every enum field reachable from the edge roots has a policy entry" do
      # A new enum field must not be silently unpoliced: this walks the real schemas and fails if any
      # reachable enum field is missing from @enum_field_policy.
      # The DOMAIN roots must be walked explicitly: EdgeRecordV1.payload is opaque BYTES, so nothing
      # under sweep / MTR / lifecycle is reachable from the record-plane roots. Without them a newly
      # added enum field on an INACTIVE or optional domain branch is invisible to this assertion --
      # the golden controls only cover branches those fixtures happen to populate, and the evolution
      # test only iterates policy entries that already exist.
      #
      # The RECOVERY graph is a domain root for the same reason, and its absence was a real hole
      # rather than a theoretical one: the two recovery enum contexts were added to the Go table and
      # the Elixir policy BY HAND. If a future nested recovery enum field were omitted from both,
      # their key sets would stay equally incomplete and the bidirectional equality assertion would
      # still pass. Walking the graph makes every reachable recovery enum field require an entry.
      roots = [
        EdgeRecordClientMessage,
        EdgeRecordV1,
        EdgeDeliveryFrameV1,
        EdgeRecordServerMessage,
        SweepObservationBatchV1,
        MtrTraceBatchV1,
        SweepExecutionEventV1,
        Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1,
        Serviceradar.Edge.V1.EdgeLossManifestPageV1,
        # The SCHEDULER-authored assignment graph is a root for the same reason the
        # recovery graph is: `SweepAssignmentState` was added to the Go table and the
        # Elixir policy BY HAND. Without walking this root, a future nested enum field
        # omitted from BOTH tables would leave their key sets equally incomplete and the
        # bidirectional equality assertion would still pass -- symmetric ignorance.
        Serviceradar.Edge.V1.SweepAssignmentRecordV1,
        # The PLAN graphs too: the assignment's authority is derived from them, so an
        # enum field added under a plan header or page is exactly as reachable -- and
        # exactly as invisible to a walk that omits its root.
        Serviceradar.Edge.V1.ScheduledPlanHeaderV1,
        Serviceradar.Edge.V1.ScheduledPlanPageV1,
        # The compiled assignment carrier: its result format and traffic class are
        # signed facts, so an unpoliced enum there would be authenticated nonsense.
        Serviceradar.Edge.V1.CompiledSweepAssignmentV1,
        Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1
      ]

      policy = SemanticValidate.enum_field_policy()

      reachable = roots |> Enum.reduce({[], MapSet.new()}, &collect_enum_fields/2) |> elem(0)
      assert reachable != []

      missing = Enum.reject(reachable, &Map.has_key?(policy, &1))
      assert missing == [], "enum fields with NO policy entry: #{inspect(missing)}"
    end

    test "an unpoliced enum field fails CLOSED rather than being waved through" do
      # UnpolicedEnumFixture is deliberately absent from @enum_field_policy.
      assert {:error, {:unpoliced_enum_field, [:state]}} =
               SemanticValidate.validate_message(%UnpolicedEnumFixture{
                 state: :EDGE_RECORD_TRAFFIC_CLASS_BULK
               })
    end

    test "every policed field rejects its zero member and accepts a real member" do
      # Zero-member vector for EVERY policed enum field, driven off the policy table itself.
      for {{mod, field}, allowed} <- SemanticValidate.enum_field_policy() do
        %{field_props: fps} = mod.__message_props__()
        fp = Enum.find_value(fps, fn {_t, fp} -> if fp.name_atom == field, do: fp end)
        {:enum, enum_mod} = fp.type

        zero = enum_mod.key(0)
        refute zero in allowed, "#{inspect(mod)}.#{field} allows its zero member"

        assert {:error, {:unsupported_enum, _}} =
                 SemanticValidate.validate_message(struct(mod, %{field => zero})),
               "#{inspect(mod)}.#{field} accepted its zero member #{inspect(zero)}"

        # A real member of the same enum is accepted for THIS field (other fields may still fail, so
        # only assert this field is not the one reported).
        real = hd(allowed)

        case SemanticValidate.validate_message(struct(mod, %{field => real})) do
          :ok -> :ok
          {:error, {_kind, path}} -> refute List.last(path) == field
        end
      end
    end
  end

  describe "domain payload families are policed AND accepted" do
    test "the Go-authored sweep / MTR / lifecycle goldens all validate" do
      # Go's golden test validates these fixtures successfully; the gate must not reject the very
      # payloads it protects. Before the domain roots were policed each returned
      # {:error, {:unpoliced_enum_field, _}}.
      assert :ok =
               "sweep_batch.bin"
               |> load()
               |> SweepObservationBatchV1.decode()
               |> SemanticValidate.validate_message()

      assert :ok =
               "mtr_batch.bin"
               |> load()
               |> MtrTraceBatchV1.decode()
               |> SemanticValidate.validate_message()

      assert :ok =
               "lifecycle.bin"
               |> load()
               |> SweepExecutionEventV1.decode()
               |> SemanticValidate.validate_message()
    end

    test "a domain enum still rejects its zero member and a retained integer" do
      batch = "lifecycle.bin" |> load() |> SweepExecutionEventV1.decode()

      assert {:error, {:unsupported_enum, [:kind]}} =
               SemanticValidate.validate_message(%{
                 batch
                 | kind: :SWEEP_EXECUTION_EVENT_KIND_UNSPECIFIED
               })

      assert {:error, {:unsupported_enum, [:kind]}} =
               SemanticValidate.validate_message(%{batch | kind: -1})
    end
  end

  describe "evaluator-READINESS failures never resolve terminally" do
    test "coverage and schema defects PAUSE instead of permanently rejecting" do
      # These mean "this release cannot evaluate the record", not "the record is invalid".
      # Reject-DLQ-ing them would destroy VALID customer data over a defect on our side, and
      # contradicts task 1.16's rule that :not_ready/:systemic yields no terminal resolution.
      for failure <- [{:unpoliced_enum_field, [:x]}, {:schema_unavailable, [:payload]}] do
        assert {:pause, ^failure} = SemanticValidate.disposition({:error, failure}, :delivery)
        assert {:pause, ^failure} = SemanticValidate.disposition({:error, failure}, :lane_open)
      end
    end

    test "genuine DATA failures still resolve terminally" do
      data = {:unsupported_enum, [:compression]}

      assert {:disposition, :REJECTED_PERMANENT, ^data} =
               SemanticValidate.disposition({:error, data}, :delivery)

      assert {:close_lane, ^data} = SemanticValidate.disposition({:error, data}, :lane_open)
    end
  end

  describe "frozen allowed sets guard enum EVOLUTION" do
    test "no enum module has a nonzero member missing from its frozen set" do
      # Deriving "every nonzero member" would AUTO-ADMIT a future member while Go's closed switches
      # keep rejecting it. The sets are frozen, so a new member must be a deliberate edit here --
      # this test is what forces that decision.
      for {{mod, field}, allowed} <- SemanticValidate.enum_field_policy() do
        %{field_props: fps} = mod.__message_props__()
        fp = Enum.find_value(fps, fn {_t, fp} -> if fp.name_atom == field, do: fp end)
        {:enum, enum_mod} = fp.type

        declared =
          enum_mod.__message_props__().field_props
          |> Enum.reject(fn {tag, _} -> tag == 0 end)
          |> Enum.map(fn {_t, fp} -> fp.name_atom end)

        undeclared = allowed -- declared

        assert undeclared == [],
               "#{inspect(mod)}.#{field} allows non-members: #{inspect(undeclared)}"

        unfrozen = declared -- allowed

        assert unfrozen == [],
               "#{inspect(enum_mod)} gained member(s) #{inspect(unfrozen)} not in the frozen set for " <>
                 "#{inspect(mod)}.#{field}. Decide deliberately whether Go accepts them too."
      end
    end
  end

  describe "GO-authored parity manifest drives the frozen sets" do
    test "every field in the Go manifest has the identical Elixir allowed set" do
      # proto/edge/v1/testdata/enum_policy_manifest.txt is written by Go by running Go's OWN
      # predicates over every declared member. Updating an Elixir list (or adding a proto member)
      # without updating the corresponding closed Go switch changes that manifest and fails here --
      # which an Elixir-internal check could never detect.
      policy = SemanticValidate.enum_field_policy()

      manifest =
        "enum_policy_manifest.txt"
        |> load()
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [field, members] = String.split(line, "\t")

          {field,
           members |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom/1)}
        end)

      assert map_size(manifest) > 0

      # EXACT key-set equality in BOTH directions: neither side may police a context the other does
      # not. Checking only manifest -> policy left 18 of 28 contexts with no Go comparison at all.
      manifest_keys =
        manifest
        |> Map.keys()
        |> MapSet.new(fn field ->
          [mod_name, field_name] = String.split(field, ".")
          {Module.concat([V1, mod_name]), String.to_existing_atom(field_name)}
        end)

      policy_keys = policy |> Map.keys() |> MapSet.new()

      assert policy_keys |> MapSet.difference(manifest_keys) |> MapSet.to_list() == [],
             "Elixir polices contexts the Go manifest does not cover"

      assert manifest_keys |> MapSet.difference(policy_keys) |> MapSet.to_list() == [],
             "the Go manifest covers contexts Elixir does not police"

      for {field, go_members} <- manifest do
        [mod_name, field_name] = String.split(field, ".")
        mod = Module.concat([V1, mod_name])
        key = {mod, String.to_existing_atom(field_name)}

        assert Map.has_key?(policy, key), "Go polices #{field} but Elixir has no entry"

        assert Enum.sort(Map.fetch!(policy, key)) == Enum.sort(go_members),
               "#{field}: Elixir allows #{inspect(Enum.sort(Map.fetch!(policy, key)))}, " <>
                 "Go accepts #{inspect(Enum.sort(go_members))}"
      end
    end
  end

  describe "malformed schema metadata is CONTAINED, never an escaping exception" do
    test "malformed FieldProps / oneof shapes become a typed readiness outcome" do
      for mod <- [BrokenSemanticProps, BrokenOneofProps] do
        assert {:error, {:schema_unavailable, _}} =
                 SemanticValidate.validate_message(struct(mod)),
               "#{inspect(mod)} escaped instead of being contained"
      end
    end

    test "NON-RAISING malformed metadata still fails closed (shape and oneof storage)" do
      # A retained integer under a shapeless FieldProps would otherwise be skipped entirely...
      # Rejected at the MODULE preflight (before any field is read), so the path is the root.
      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(struct(ShapelessFieldProps, %{x: -1}))

      # ...and a SET oneof member whose declared storage key is absent from the struct would read as
      # "a different member is active" and be skipped too.
      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(
                 struct(WrongOneofStorageProps, %{choice: {:state, -1}})
               )
    end

    test "a negative or mismatched oneof index is metadata drift, not an absent field" do
      for mod <- [NegativeOneofIndexProps, MismatchedOneofIndexProps] do
        assert {:error, {:schema_unavailable, _}} =
                 SemanticValidate.validate_message(struct(mod)),
               "#{inspect(mod)} silently skipped the field instead of surfacing the drift"
      end
    end

    test "the four non-raising drift shapes and the orphan oneof all fail closed" do
      cases = [
        {MissingOrdinaryStorageProps, %{present: 1}},
        {IncoherentFlagsProps, %{x: -1}},
        {NonBooleanMapFlagProps, %{m: %{"k" => -1}}},
        {BadMapEntryValueProps, %{m: %{"k" => -1}}},
        {OrphanOneofProps, %{choice: {:state, -1}}}
      ]

      for {mod, fields} <- cases do
        assert {:error, {:schema_unavailable, _}} =
                 SemanticValidate.validate_message(struct(mod, fields)),
               "#{inspect(mod)} returned :ok -- a retained non-member would be silently skipped"
      end
    end

    test "graph congruence: undescribed storage, unloadable modules, bad entry, untyped oneof value" do
      cases = [
        {UndescribedStorageProps, %{}},
        {UnloadableEnumProps, %{x: -1}},
        {UnloadableChildProps, %{child: 99}},
        {BadEntryStorageMap, %{m: %{"k" => -1}}},
        {UntypedOneofValueProps, %{choice: {:child, -1}}}
      ]

      for {mod, fields} <- cases do
        assert {:error, {:schema_unavailable, _}} =
                 SemanticValidate.validate_message(struct(mod, fields)),
               "#{inspect(mod)} returned :ok -- a retained value could escape validation"
      end
    end

    test "a CYCLIC malformed map Entry terminates instead of hanging" do
      # Bounded: a regression for nontermination must never be able to wedge the suite.
      task =
        Task.async(fn ->
          SemanticValidate.validate_message(struct(CyclicMapProps, %{m: %{}}))
        end)

      assert {:ok, {:error, {:schema_unavailable, _}}} =
               Task.yield(task, 5_000) ||
                 {:timeout, Task.shutdown(task)}
    end

    test "the schema cache is keyed by module BINARY, so hot replacement is not served stale" do
      # Cache a verdict for a module, then redefine that same module with storage no metadata
      # describes. A cache keyed only by module name would keep returning the old verdict.
      defmodule HotSwapProbe do
        @moduledoc false
        defstruct [:x]

        def __message_props__ do
          %{
            field_props: %{
              1 => %{
                name_atom: :x,
                enum?: true,
                embedded?: false,
                repeated?: false,
                map?: false,
                oneof: nil,
                type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}
              }
            },
            oneof: []
          }
        end
      end

      assert {:error, {:unsupported_enum, [:x]}} =
               SemanticValidate.validate_message(struct(HotSwapProbe, %{x: -1}))

      :code.purge(HotSwapProbe)
      :code.delete(HotSwapProbe)

      Code.compile_string("""
      defmodule #{inspect(HotSwapProbe)} do
        defstruct [:x, :sneaky]

        def __message_props__ do
          %{field_props: %{1 => %{name_atom: :x, enum?: true, embedded?: false, repeated?: false,
            map?: false, oneof: nil, type: {:enum, Serviceradar.Edge.V1.EdgeRecordTrafficClass}}},
            oneof: []}
        end
      end
      """)

      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(struct(HotSwapProbe, %{x: -1}))
    end

    test "container SHAPE is part of the contract: repeated needs a list, map needs a plain map" do
      # A repeated embedded field holding ONE struct previously fell through to the singular clause.
      kid = struct(ShapeKid, %{v: 1})

      assert {:error, {:schema_unavailable, [:kids]}} =
               SemanticValidate.validate_message(struct(RepeatedEmbeddedProps, %{kids: kid}))

      assert :ok =
               SemanticValidate.validate_message(struct(RepeatedEmbeddedProps, %{kids: [kid]}))

      # A repeated enum holding ONE bare value was normalised by List.wrap/1.
      assert {:error, {:schema_unavailable, [:tags]}} =
               SemanticValidate.validate_message(
                 struct(RepeatedEnumProps, %{tags: :EDGE_RECORD_TRAFFIC_CLASS_BULK})
               )

      # A well-shaped list reaches the value check (unpoliced here because this synthetic field has
      # no policy entry) -- proving the walk actually descended rather than skipping the field.
      assert {:error, {:unpoliced_enum_field, [:tags]}} =
               SemanticValidate.validate_message(
                 struct(RepeatedEnumProps, %{tags: [:EDGE_RECORD_TRAFFIC_CLASS_BULK]})
               )
    end

    test "a canonical-shaped Entry with INCOHERENT value FieldProps is rejected" do
      # The Entry shell passes (map? marker, tags 1/2, legal string key, non-map value), but tag 2
      # declares an enum type with `enum?: false`. Dispatching on that flag would classify the value
      # as a scalar and skip the retained -1 entirely, so the Entry must pass FULL local congruence
      # before its metadata is trusted.
      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(
                 struct(IncoherentEntryHolder, %{m: %{"k" => -1}})
               )
    end

    test "an ordinary message used as a map Entry is rejected (no map-entry marker)" do
      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(struct(FakeMapProps, %{m: %{}}))
    end

    test "a schema hot-replaced and rolled back never admits retained invalid enum data" do
      # REGRESSION for the cache race that this validator's `:persistent_term` memo made possible.
      #
      # The cache derived its key from a LIVE read of the module (own MD5 plus a direct-dependency
      # fingerprint) and then reread that module independently when computing the value. A hot
      # replacement landing between those two reads published the REPLACEMENT's props under the
      # ORIGINAL module's key. Restoring the original binary then served the stale entry -- an empty
      # schema, which validates nothing -- so a retained invalid enum was ADMITTED (`:ok`).
      #
      # The cache is gone and the verdict is recomputed per call, so no interleaving of replacement
      # and rollback can produce an admit. Asserting "never `:ok`" is the durable property: which
      # non-ok failure is reported depends on policy coverage for a synthetic module, but an admit
      # is always wrong.
      defmodule_src = fn body ->
        """
        defmodule RacedSchemaProbe do
          use Protobuf, syntax: :proto3

          #{body}
        end
        """
      end

      populated = defmodule_src.("field(:kind, 1, type: RacedSchemaProbeEnum, enum: true)")
      emptied = defmodule_src.("")

      Code.compile_string("""
      defmodule RacedSchemaProbeEnum do
        use Protobuf, enum: true, syntax: :proto3

        field(:RACED_SCHEMA_PROBE_ENUM_UNSPECIFIED, 0)
        field(:RACED_SCHEMA_PROBE_ENUM_A, 1)
      end
      """)

      compile = fn src ->
        ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(src) end)
      end

      compile.(populated)
      invalid = struct(RacedSchemaProbe, %{kind: -1})

      before = SemanticValidate.validate_message(invalid)
      refute before == :ok, "a retained -1 enum must never be admitted"

      # Hot replacement with a schema that describes nothing, then rollback to the ORIGINAL shape.
      compile.(emptied)
      _ = SemanticValidate.validate_message(struct(RacedSchemaProbe, %{}))
      compile.(populated)

      after_rollback = SemanticValidate.validate_message(struct(RacedSchemaProbe, %{kind: -1}))

      refute after_rollback == :ok,
             "invalid enum admitted after hot replacement + rollback: stale schema was reused"
    end

    test "no schema verdict is memoised in :persistent_term" do
      # The memo is the mechanism the race needed. If one is reintroduced, this fails and the
      # interleaving regression above must be re-argued rather than silently weakened.
      record = EdgeRecordV1.decode(load("record.bin"))
      assert :ok = SemanticValidate.validate_record(record)

      memoised =
        Enum.filter(:persistent_term.get(), fn
          {{SemanticValidate, :schema, _, _, _, _}, _} -> true
          {{SemanticValidate, :schema, _, _}, _} -> true
          _ -> false
        end)

      assert memoised == [],
             "SemanticValidate must not memoise schema verdicts: #{inspect(memoised)}"
    end

    test "a TRANSITIVE readiness failure is not pinned once the missing module loads" do
      # `validate_module/1` consumes transitive state (a map Entry's own enum reference), but the
      # holder's fingerprint covers only its DIRECT Entry module. Caching the failure would leave the
      # holder paused until process restart even after the enum became available, so readiness
      # FAILURES are never cached.
      holder = struct(GrandchildHolder, %{m: %{}})

      assert {:error, {:schema_unavailable, _}} = SemanticValidate.validate_message(holder)

      Code.compile_string("""
      defmodule LateLoadedMapEnum do
        use Protobuf, enum: true, syntax: :proto3

        field(:LATE_LOADED_MAP_ENUM_UNSPECIFIED, 0)
        field(:LATE_LOADED_MAP_ENUM_A, 1)
      end
      """)

      # The readiness failure must CLEAR. (The synthetic Entry field has no policy entry, so the
      # walk then reports that coverage gap -- what matters here is that it is no longer pinned on
      # schema readiness.)
      refute match?({:error, {:schema_unavailable, _}}, SemanticValidate.validate_message(holder))
    end

    test "a child-only load or replacement is not served a stale cached verdict" do
      # 1. Parent validated while its child is MISSING, then the child loads: the error must clear.
      defmodule StaleParentA do
        @moduledoc false
        defstruct [:child]

        def __message_props__ do
          %{
            field_props: %{
              1 => %{
                name_atom: :child,
                enum?: false,
                embedded?: true,
                repeated?: false,
                map?: false,
                oneof: nil,
                type: LateLoadedChild
              }
            },
            oneof: []
          }
        end
      end

      assert {:error, {:schema_unavailable, _}} =
               SemanticValidate.validate_message(struct(StaleParentA, %{}))

      Code.compile_string("""
      defmodule LateLoadedChild do
        defstruct [:v]

        def __message_props__ do
          %{field_props: %{1 => %{name_atom: :v, enum?: false, embedded?: false, repeated?: false,
            map?: false, oneof: nil, type: :int32}}, oneof: []}
        end
      end
      """)

      assert :ok = SemanticValidate.validate_message(struct(StaleParentA, %{}))

      # 2. Valid parent cached, then ONLY the child is replaced with reverse-storage-invalid
      #    metadata: validation THROUGH the unchanged parent must see it.
      Code.compile_string("""
      defmodule SwappedChild do
        defstruct [:v]

        def __message_props__ do
          %{field_props: %{1 => %{name_atom: :v, enum?: false, embedded?: false, repeated?: false,
            map?: false, oneof: nil, type: :int32}}, oneof: []}
        end
      end
      """)

      defmodule StaleParentB do
        @moduledoc false
        defstruct [:child]

        def __message_props__ do
          %{
            field_props: %{
              1 => %{
                name_atom: :child,
                enum?: false,
                embedded?: true,
                repeated?: false,
                map?: false,
                oneof: nil,
                type: SwappedChild
              }
            },
            oneof: []
          }
        end
      end

      assert :ok =
               SemanticValidate.validate_message(
                 struct(StaleParentB, %{child: struct(SwappedChild, %{v: 1})})
               )

      :code.purge(SwappedChild)
      :code.delete(SwappedChild)

      Code.compile_string("""
      defmodule SwappedChild do
        defstruct [:v, :undescribed]

        def __message_props__ do
          %{field_props: %{1 => %{name_atom: :v, enum?: false, embedded?: false, repeated?: false,
            map?: false, oneof: nil, type: :int32}}, oneof: []}
        end
      end
      """)

      assert {:error, {:schema_unavailable, [:child]}} =
               SemanticValidate.validate_message(
                 struct(StaleParentB, %{child: struct(SwappedChild, %{v: 1})})
               )
    end

    test "metadata that raises, throws, or exits becomes a typed readiness outcome" do
      for mod <- [RaisingSemanticProps, ThrowingSemanticProps, ExitingSemanticProps] do
        assert {:error, {:schema_unavailable, _}} = SemanticValidate.validate_message(struct(mod))
      end
    end

    test "and every such failure PAUSES rather than resolving terminally" do
      outcome = SemanticValidate.validate_message(struct(BrokenSemanticProps))
      assert {:pause, {:schema_unavailable, _}} = SemanticValidate.disposition(outcome, :delivery)
    end
  end

  describe "recursion boundary matches the shared bound" do
    test "10,000 nested messages accepted; the 10,001st rejected as :max_depth_exceeded" do
      # This boundary was previously off by one here (accepting 10,001), so pin N/N+1 explicitly.
      # Built as decoded structs, since this gate runs on the DECODED graph.
      nest = fn depth ->
        Enum.reduce(1..depth, %RecursiveSemanticFixture{}, fn _, acc ->
          %RecursiveSemanticFixture{next: acc}
        end)
      end

      assert :ok = SemanticValidate.validate_message(nest.(9_999))

      assert {:error, {:max_depth_exceeded, _}} =
               SemanticValidate.validate_message(nest.(10_000))
    end
  end

  describe "no over-rejection and totality" do
    test "each known member of the frozen sets is accepted" do
      for member <- [:EDGE_RECORD_TRAFFIC_CLASS_BULK, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE] do
        open = %EdgeRecordLaneOpen{
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: member
        }

        assert :ok = SemanticValidate.validate_lane_open(open)
      end
    end

    test "a record with NO source_authorization is accepted (absence is explicit, as in Go)" do
      record = EdgeRecordV1.decode(load("record_no_source.bin"))
      assert record.source_authorization == nil
      assert :ok = SemanticValidate.validate_record(record)
    end

    test "a non-struct input is a typed failure, never a raise" do
      assert {:error, {:unsupported_enum, [:record]}} = SemanticValidate.validate_record(:nope)

      assert {:error, {:unsupported_enum, [:lane_open]}} =
               SemanticValidate.validate_lane_open(%{})

      assert :ok = SemanticValidate.validate_message(:not_a_struct)
    end
  end
end
