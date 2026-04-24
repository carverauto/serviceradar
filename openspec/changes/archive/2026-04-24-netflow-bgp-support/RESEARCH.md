# BGP IPFIX Information Elements Research

## BGP Communities - SUPPORTED ✓

### Standard IANA Elements (RFC 8549)
The following BGP community elements are defined in RFC 8549 and **supported by netflow_parser v0.9.0**:

- **Element 483**: `BgpCommunity` - unsigned32 (individual community value)
- **Element 484**: `BgpSourceCommunityList` - String (basicList in IPFIX)
- **Element 485**: `BgpDestinationCommunityList` - String (basicList in IPFIX)
- **Element 486**: `BgpExtendedCommunity` - String (octetArray in IPFIX)
- **Element 487**: `BgpSourceExtendedCommunityList` - String (basicList in IPFIX)
- **Element 488**: `BgpDestinationExtendedCommunityList` - String (basicList in IPFIX)

### netflow_parser Mapping
```rust
BgpCommunity = 483 => FieldDataType::UnsignedDataNumber
BgpSourceCommunityList = 484 => FieldDataType::String
BgpDestinationCommunityList = 485 => FieldDataType::String
BgpExtendedCommunity = 486 => FieldDataType::String
BgpSourceExtendedCommunityList = 487 => FieldDataType::String
BgpDestinationExtendedCommunityList = 488 => FieldDataType::String
```

## BGP AS Path - NOT STANDARDIZED ⚠️

### Individual AS Number Elements (Supported)
- **Element 16**: `BgpSourceAsNumber` - unsigned32
- **Element 17**: `BgpDestinationAsNumber` - unsigned32
- **Element 128**: `BgpNextAdjacentAsNumber` - unsigned32
- **Element 129**: `BgpPrevAdjacentAsNumber` - unsigned32

### AS Path Sequence
**No standard IANA IPFIX information element exists for full BGP AS path sequence.**

The IANA registry only defines individual AS numbers (source, destination, adjacent). A full AS path (sequence of all ASNs) would require:
1. Vendor-specific enterprise information elements, OR
2. Multiple template records, OR
3. Constructing path from source/destination AS numbers (incomplete)

## Implementation Strategy

### For BGP Communities
Use standard IPFIX fields that are already supported by netflow_parser:
- Extract `BgpSourceCommunityList` or `BgpDestinationCommunityList`
- Parse the string/list format into `repeated uint32` for protobuf
- Individual communities via `BgpCommunity` if list not available

### For AS Path
Since no standard field exists, we have **two options**:

**Option 1: Vendor-Specific Fields** (Cisco/Juniper)
- Check if vendors export AS path in enterprise-specific IEs
- Would require mapping vendor enterprise IDs
- Most flexible but vendor-dependent

**Option 2: Construct from Available Fields** (Limited)
- Use source AS + destination AS as a 2-hop path
- Include adjacent AS if available for 3-4 hop visibility
- Incomplete but uses standard fields only

## Recommendation
1. **Implement BGP Communities** using standard IPFIX fields 484/485 (high priority, well-supported)
2. **AS Path** - Start with Option 2 (construct from available fields), document limitation
3. **Future Enhancement** - Add vendor-specific AS path support when needed

## Sources
- [RFC 8549 - Export of BGP Community Information in IPFIX](https://datatracker.ietf.org/doc/rfc8549/)
- [IANA IPFIX Information Elements Registry](https://www.iana.org/assignments/ipfix/ipfix.xml)
- [RFC 7012 - IPFIX Information Model](https://www.rfc-editor.org/rfc/rfc7012.html)
- netflow_parser v0.9.0 source code inspection
