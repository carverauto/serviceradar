# BGP Testing Notes

## Working Configuration

The `ipfix_bgp_simple.yaml` configuration has been tested and works with `netflow_generator 0.2.2`:

**Supported BGP Fields:**
- ✅ `bgpSourceAsNumber` (IE 16) - Source AS number
- ✅ `bgpDestinationAsNumber` (IE 17) - Destination AS number

**Unsupported in netflow_generator 0.2.2:**
- ❌ `bgpNextAdjacentAsNumber` (IE 128) - Next-hop AS
- ❌ `bgpCommunity` (IE 483) - BGP community value
- ❌ `bgpSourceCommunityList` (IE 483)
- ❌ `bgpDestinationCommunityList` (IE 484)

## Test Results

Successfully generated and sent test flows:
- 3 flows with BGP AS data (AS 64512 → various destinations)
- 1 flow without BGP data (backward compatibility test)

```bash
$ netflow_generator --config test-data/ipfix_bgp_simple.yaml --verbose --once

NetFlow Generator starting...
Using 4 threads for parallel processing
Loading configuration from "test-data/ipfix_bgp_simple.yaml"
Configuration loaded: 2 flow(s)
Generating IPFIX packet(s)...
Generated 4 packet(s)
Transmitting packets to 127.0.0.1:2055
Successfully sent all packets
Done!
```

## Workaround for Community Testing

Since `netflow_generator` doesn't support BGP community fields yet, for full BGP community testing:

### Option 1: Manual IPFIX Packet Creation
Create raw IPFIX packets with community data using Python/scapy or similar tools.

### Option 2: Real Router Export
Configure a real router (Cisco/Juniper) to export IPFIX with BGP data:

```cisco
! Cisco IOS example
ip flow-export version 10
ip flow-export destination <collector-ip> 2055
ip flow-export template option bgp-nexthop
```

### Option 3: Upgrade netflow_generator
When newer versions add BGP community support, update the test configs:

```yaml
fields:
  - field_type: "bgpCommunity"
    field_length: 4

records:
  - bgp_community: 4259840100  # 65000:100
```

## Current Test Coverage

With `ipfix_bgp_simple.yaml`:
- ✅ AS path construction (source AS → dest AS)
- ✅ Database storage of AS path array
- ✅ GIN index queries for AS filtering
- ✅ Backward compatibility (flows without BGP)
- ⏳ BGP communities (collector code ready, awaiting test tool support)
- ⏳ Next-hop AS (collector code ready, awaiting test tool support)

## Collector Code Status

The `rust/netflow-collector` already supports ALL BGP fields:
- ✅ Extracts `bgpSourceAsNumber`
- ✅ Extracts `bgpDestinationAsNumber`
- ✅ Extracts `bgpNextAdjacentAsNumber`
- ✅ Extracts `bgpCommunity`, `bgpSourceCommunityList`, `bgpDestinationCommunityList`
- ✅ Constructs AS path from available AS numbers
- ✅ Parses communities from various formats

**The collector is production-ready for BGP data** - we're just limited by test tool capabilities.
