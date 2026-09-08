# Tasks: Device Discovery Workflow

## Phase 1: Discovery Infrastructure

### 1.1 Discovery Job System
- [ ] 1.1.1 Create ServiceRadar.Discovery domain module
- [ ] 1.1.2 Create DiscoveryRequest Ash resource (target, type, status, results)
- [ ] 1.1.3 Add AshStateMachine for discovery states (pending, running, completed, failed)
- [ ] 1.1.4 Create DiscoveryWorker Oban job (partition/tenant aware)
- [ ] 1.1.5 Implement agent selection for discovery dispatch
- [ ] 1.1.6 Add database migration for discovery_requests table
- [ ] 1.1.7 Create DiscoveryResult Ash resource for storing raw results

### 1.2 Agent Discovery Dispatch
- [ ] 1.2.1 Add discovery capability to AgentRegistry metadata
- [ ] 1.2.2 Create find_agent_for_discovery/2 (partition, capabilities)
- [ ] 1.2.3 Implement discovery request dispatch via ERTS RPC
- [ ] 1.2.4 Add discovery progress reporting via PubSub
- [ ] 1.2.5 Handle discovery timeout and retry logic

## Phase 2: Discovery LiveView

### 2.1 Add Device Form
- [ ] 2.1.1 Create DiscoveryLive.New LiveView
- [ ] 2.1.2 Add target input (IP/hostname)
- [ ] 2.1.3 Add partition selector dropdown
- [ ] 2.1.4 Add discovery type selector (auto, snmp, ping, tcp)
- [ ] 2.1.5 Add SNMP credentials section (community string, version)
- [ ] 2.1.6 Implement form validation (IP format, required fields)
- [ ] 2.1.7 Add route for /devices/new

### 2.2 Discovery Progress
- [ ] 2.2.1 Create DiscoveryLive.Progress component
- [ ] 2.2.2 Subscribe to discovery PubSub topic
- [ ] 2.2.3 Display discovery stages (ping, snmp, ports)
- [ ] 2.2.4 Show real-time status updates
- [ ] 2.2.5 Handle discovery errors gracefully
- [ ] 2.2.6 Add cancel discovery button

### 2.3 Discovery Results
- [ ] 2.3.1 Create DiscoveryLive.Results component
- [ ] 2.3.2 Display device summary (type, vendor, model)
- [ ] 2.3.3 Display discovered interfaces table
- [ ] 2.3.4 Add interface selection checkboxes
- [ ] 2.3.5 Display discovered services/ports
- [ ] 2.3.6 Add "Configure Monitoring" button

## Phase 3: Mapper Integration (SNMP)

### 3.1 Mapper gRPC Client
- [ ] 3.1.1 Create ServiceRadar.Mapper.Client GenServer
- [ ] 3.1.2 Implement SNMPWalk RPC call
- [ ] 3.1.3 Implement GetDeviceInfo RPC call
- [ ] 3.1.4 Implement GetInterfaces RPC call
- [ ] 3.1.5 Add mTLS support for mapper connection
- [ ] 3.1.6 Handle gRPC streaming responses

### 3.2 SNMP Discovery Processing
- [ ] 3.2.1 Create SNMPDiscoveryProcessor module
- [ ] 3.2.2 Parse sysDescr for device classification
- [ ] 3.2.3 Parse ifTable for interface details
- [ ] 3.2.4 Extract interface counters (ifInOctets, ifOutOctets, etc.)
- [ ] 3.2.5 Determine interface types (ethernet, vlan, loopback)
- [ ] 3.2.6 Store interface data in DiscoveredInterface resource

### 3.3 Device Classification
- [ ] 3.3.1 Create DeviceClassifier module
- [ ] 3.3.2 Implement vendor detection from sysObjectID
- [ ] 3.3.3 Implement device type detection (router, switch, server, etc.)
- [ ] 3.3.4 Map to OCSF device types
- [ ] 3.3.5 Store classification in device record

## Phase 4: Interface Monitoring Configuration

### 4.1 Interface Selection UI
- [ ] 4.1.1 Create InterfaceSelectionLive component
- [ ] 4.1.2 Display interface table with selectable rows
- [ ] 4.1.3 Show interface details (name, type, speed, admin status)
- [ ] 4.1.4 Add "Select All" / "Deselect All" buttons
- [ ] 4.1.5 Add per-interface poll interval config
- [ ] 4.1.6 Add interface search/filter

### 4.2 Monitoring Configuration
- [ ] 4.2.1 Create InterfaceMonitor Ash resource
- [ ] 4.2.2 Define SNMP OID sets per interface type
- [ ] 4.2.3 Create monitoring config from selected interfaces
- [ ] 4.2.4 Generate ServiceChecks for each interface
- [ ] 4.2.5 Add monitoring config to device record
- [ ] 4.2.6 Create database migration for interface_monitors table

### 4.3 SNMP Metrics Collection
- [ ] 4.3.1 Create SNMPCollectorJob Oban worker
- [ ] 4.3.2 Implement interface counter polling
- [ ] 4.3.3 Calculate deltas for counter metrics
- [ ] 4.3.4 Store metrics in TimescaleDB hypertable
- [ ] 4.3.5 Add interface utilization calculation
- [ ] 4.3.6 Emit telemetry for collection stats

## Phase 5: Sweep Integration (TCP/ICMP)

### 5.1 Sweep gRPC Client
- [ ] 5.1.1 Create ServiceRadar.Sweep.Client GenServer
- [ ] 5.1.2 Implement PingSweep RPC call
- [ ] 5.1.3 Implement PortScan RPC call
- [ ] 5.1.4 Handle streaming results from sweep
- [ ] 5.1.5 Add mTLS support for sweep connection

### 5.2 Port Discovery Processing
- [ ] 5.2.1 Create PortDiscoveryProcessor module
- [ ] 5.2.2 Parse open ports from scan results
- [ ] 5.2.3 Match ports to common services
- [ ] 5.2.4 Store discovered ports in DiscoveredService resource
- [ ] 5.2.5 Suggest monitoring based on discovered services

### 5.3 Ping Check Setup
- [ ] 5.3.1 Create ping ServiceCheck from discovery
- [ ] 5.3.2 Configure ping interval and thresholds
- [ ] 5.3.3 Store ICMP metrics in TimescaleDB
- [ ] 5.3.4 Add ping sparkline to device inventory

## Phase 6: DIRE Integration

### 6.1 Device Identity
- [ ] 6.1.1 Call DIRE on discovery completion
- [ ] 6.1.2 Create/merge device based on identity resolution
- [ ] 6.1.3 Update device with discovered attributes
- [ ] 6.1.4 Link interfaces to canonical device record
- [ ] 6.1.5 Handle IP/MAC conflicts with existing devices

### 6.2 Device Inventory Updates
- [ ] 6.2.1 Add discovered device to inventory
- [ ] 6.2.2 Update device type and classification
- [ ] 6.2.3 Add vendor/model information
- [ ] 6.2.4 Link monitoring configs to device
- [ ] 6.2.5 Refresh device inventory LiveView

## Phase 7: UI Polish and Integration

### 7.1 Navigation
- [ ] 7.1.1 Add "Add Device" button to device inventory
- [ ] 7.1.2 Add discovery link to sidebar (if applicable)
- [ ] 7.1.3 Update device detail page with interfaces tab
- [ ] 7.1.4 Add interface metrics visualization

### 7.2 Error Handling
- [ ] 7.2.1 Add discovery failure notifications
- [ ] 7.2.2 Show credential errors clearly
- [ ] 7.2.3 Handle unreachable device gracefully
- [ ] 7.2.4 Add retry discovery option
- [ ] 7.2.5 Log discovery events for troubleshooting

### 7.3 Testing
- [ ] 7.3.1 Write tests for DiscoveryWorker
- [ ] 7.3.2 Write tests for device classification
- [ ] 7.3.3 Write tests for interface selection
- [ ] 7.3.4 Write integration tests for discovery flow
- [ ] 7.3.5 Write LiveView tests for discovery UI
