## Context

ServiceRadar's IPFIX v10 collector (`rust/netflow-collector`) currently extracts basic BGP information elements from flow records:
- BGP AS numbers (source, destination, next-hop AS)
- BGP next-hop IP addresses

However, the protobuf schema (`proto/flow/flow.proto`) defines additional BGP fields that are not being populated:
- `bgp_communities` (repeated uint32) - BGP community attributes for policy routing
- `as_path` (repeated uint32) - AS path sequence showing routing path

The `netflow_parser` library v0.9.0 provides access to IPFIX information elements through the `IANAIPFixField` enum. We need to identify which IPFIX IEs map to these BGP fields and extend the converter to extract them.

## Goals / Non-Goals

**Goals:**
- Extract BGP communities and AS path from IPFIX v10 flow records
- Display BGP routing information in the UI for network visibility
- Maintain backward compatibility with existing flow data

**Non-Goals:**
- Support NetFlow v5/v9 BGP fields (IPFIX v10 only)
- Add new BGP information elements beyond communities and AS path
- Real-time BGP routing table analysis (this is flow-based visibility, not BGP protocol monitoring)
- BGP session state tracking

## Decisions

### 1. IPFIX Information Element Mapping

**Decision:** Use vendor-specific or enterprise IPFIX information elements for BGP communities and AS path, as standard IANA registry may not define these fields.

**Rationale:**
- IANA IPFIX registry defines basic BGP fields (IE 16, 17, 18, 19, 63) which are already handled
- BGP communities and AS path are typically vendor-specific (e.g., Cisco uses enterprise-specific IEs)
- The `netflow_parser` library supports both IANA and vendor-specific fields through the `IPFixField` enum

**Alternative Considered:** Wait for `netflow_parser` to add explicit support for these fields
- Rejected: We can handle vendor-specific IEs now without waiting for library updates

**Implementation:**
- Check `netflow_parser` documentation/source for enterprise IE support
- If available as `IPFixField::IANA(IANAIPFixField::BgpCommunity)` or similar, use it
- Otherwise, match on enterprise-specific IEs using pattern matching on field ID

### 2. AS Path Representation

**Decision:** Store AS path as `repeated uint32` where each element is one AS number in the path sequence.

**Rationale:**
- Protobuf schema already defines `as_path` as `repeated uint32`
- This matches the BGP AS_PATH attribute structure (sequence of ASNs)
- Order is preserved, allowing path analysis in the UI

**Alternative Considered:** Store as a string (e.g., "64512 64513 64514")
- Rejected: Less efficient for storage and querying, requires parsing in UI

### 3. BGP Communities Format

**Decision:** Store BGP communities as `repeated uint32` where each value encodes the 32-bit community (high 16 bits = AS, low 16 bits = value).

**Rationale:**
- Standard BGP community format (RFC 1997) uses 32-bit values
- Protobuf schema defines `bgp_communities` as `repeated uint32`
- UI can decode into "AS:value" notation (e.g., "65000:100")

**Alternative Considered:** Store as strings in "AS:value" format
- Rejected: Less efficient, requires string parsing for filtering/indexing

### 4. Backward Compatibility

**Decision:** Only populate BGP fields when present in IPFIX records. Leave fields empty (default protobuf values) when not available.

**Rationale:**
- Existing flows without BGP information elements will continue to work
- No schema migration needed
- UI can check if fields are populated before displaying BGP-specific views

## Risks / Trade-offs

**[Risk]** Vendor-specific IPFIX field IDs vary across exporters → **Mitigation:** Document supported vendors (start with Cisco, Juniper) and create a mapping table for enterprise-specific IEs. Make field extraction configurable if needed.

**[Risk]** AS path can be very long in some scenarios (e.g., 20+ ASNs) → **Mitigation:** Protobuf `repeated` fields handle variable length efficiently. Consider adding a maximum length limit if storage becomes an issue (e.g., cap at 50 ASNs).

**[Risk]** Not all network devices export BGP information elements → **Mitigation:** BGP fields are optional. Flows without BGP data will continue to work normally. UI should handle missing BGP fields gracefully.

**[Trade-off]** Adding more fields increases flow record size → **Acceptance:** BGP fields are only populated when present in IPFIX exports. The additional data provides valuable routing visibility that justifies the storage cost.

## Migration Plan

**Deployment:**
1. Update `rust/netflow-collector` converter to extract BGP communities and AS path
2. Deploy updated collector (no protobuf schema change needed - fields already exist)
3. Verify BGP fields are being populated in NATS flow stream
4. Update Elixir ingestion to store BGP fields in database
5. Add UI components to display BGP information

**Rollback:**
- If issues arise, redeploy previous collector version
- BGP fields will simply be empty (no data loss or corruption risk)
- No database migration needed (fields are nullable/optional)

**Testing:**
- Test with IPFIX exports from Cisco and Juniper devices
- Verify AS path and communities are correctly extracted
- Confirm existing flows without BGP data are unaffected

## Open Questions

1. Which specific vendor IPFIX enterprise IDs need to be supported for BGP communities and AS path? (Need to check `netflow_parser` library capabilities and device export formats)
2. Should we add filtering/indexing on BGP fields in the database for querying by AS or community?
3. What UI visualizations are most useful for BGP flow data? (AS path graph, community-based filtering, per-AS traffic metrics?)
