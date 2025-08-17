# Device Configuration Guide

This guide provides detailed instructions for configuring network devices to send monitoring data to ServiceRadar via SNMP, Syslog, and SNMP traps.

## Overview

ServiceRadar can collect data from network devices through multiple protocols:

- **SNMP Polling**: Active monitoring via SNMP GET requests
- **Syslog**: Log message collection via UDP/TCP
- **SNMP Traps**: Event notifications from devices
- **ICMP**: Network reachability testing

## SNMP Configuration

### SNMP Prerequisites

Before configuring SNMP on devices:

1. **Determine SNMP version**: SNMPv2c (community-based) or SNMPv3 (secure)
2. **Plan community strings**: Use secure, unique strings for each device class
3. **Network access**: Ensure ServiceRadar can reach devices on UDP port 161
4. **Security**: Consider read-only access for monitoring

### Cisco IOS/IOS-XE Devices

#### Basic SNMP v2c Configuration

```cisco
! Enable SNMP v2c with read-only community
snmp-server community monitoring RO
snmp-server community private RW

! Set system information
snmp-server location "Data Center 1, Rack 42"
snmp-server contact "Network Team <network@company.com>"

! Enable SNMP traps
snmp-server enable traps snmp
snmp-server enable traps config
snmp-server enable traps entity
snmp-server enable traps envmon
snmp-server enable traps flash
snmp-server enable traps power-ethernet
snmp-server enable traps cpu threshold

! Configure trap destination
snmp-server host 192.168.1.100 monitoring

! Optional: Restrict SNMP access by source IP
access-list 10 permit 192.168.1.100
snmp-server community monitoring RO 10
```

#### SNMP v3 Configuration (Recommended)

```cisco
! Create SNMP v3 user with authentication and privacy
snmp-server user serviceradar-user serviceradar-group v3 auth sha serviceradar-auth-key priv aes 256 serviceradar-priv-key

! Create SNMP group with read access
snmp-server group serviceradar-group v3 priv read iso context serviceradar-context

! Enable SNMP v3 traps
snmp-server host 192.168.1.100 version 3 priv serviceradar-user
```

### Cisco Nexus Devices

```cisco
! Enable SNMP v2c
snmp-server community monitoring group network-operator
snmp-server community private group network-admin

! Configure system information
snmp-server location "Data Center 1, Switch Stack A"
snmp-server contact "Network Operations <netops@company.com>"

! Enable traps
snmp-server enable traps
snmp-server enable traps link
snmp-server enable traps rf
snmp-server enable traps feature-control
snmp-server enable traps license
snmp-server enable traps cfs
snmp-server enable traps config

! Configure trap destination
snmp-server host 192.168.1.100 traps version 2c monitoring
```

### Juniper JunOS Devices

```junos
# Configure SNMP v2c
set snmp community monitoring authorization read-only
set snmp community private authorization read-write

# Set system information
set snmp location "Data Center 1, Core Router"
set snmp contact "Network Engineering <neteng@company.com>"

# Configure trap destinations
set snmp trap-group serviceradar version v2
set snmp trap-group serviceradar targets 192.168.1.100

# Enable specific traps
set snmp trap-options source-address 10.0.0.1
```

### Arista EOS Devices

```eos
! Enable SNMP v2c
snmp-server community monitoring ro
snmp-server community private rw

! Set system information
snmp-server location "Edge Location 1"
snmp-server contact "Network Team <network@company.com>"

! Enable traps
snmp-server enable traps
snmp-server host 192.168.1.100 version 2c monitoring
```

### Linux/Unix Systems

#### Net-SNMP Configuration

Edit `/etc/snmp/snmpd.conf`:

```bash
# Community configuration
rocommunity monitoring 192.168.1.100
rwcommunity private 192.168.1.100

# System information
syslocation "Server Room A, Rack 10"
syscontact "System Admin <sysadmin@company.com>"

# Security settings
agentAddress udp:161

# Process monitoring
proc httpd
proc sshd
proc ntpd

# Disk monitoring
disk / 10%
disk /var 15%
disk /tmp 10%

# Load monitoring
load 12 10 5

# Extend with custom scripts
extend temperature /usr/local/bin/get-temperature.sh
extend disk-usage /usr/local/bin/disk-usage.sh
```

Start and enable the SNMP daemon:

```bash
sudo systemctl enable snmpd
sudo systemctl start snmpd
sudo systemctl status snmpd
```

#### SNMP v3 Configuration

Add to `/etc/snmp/snmpd.conf`:

```bash
# Create SNMP v3 user
createUser serviceradar-user SHA "serviceradar-auth-password" AES "serviceradar-priv-password"

# Configure access
rouser serviceradar-user priv
```

## Syslog Configuration

### Centralized Logging Setup

ServiceRadar collects syslog messages on UDP port 514. Configure devices to forward logs:

### Cisco IOS/IOS-XE Syslog

```cisco
! Configure syslog server
logging host 192.168.1.100

! Set logging level (0=emergency, 7=debug)
logging trap informational

! Optional: Set logging source interface
logging source-interface Loopback0

! Configure logging facility
logging facility local0

! Enable specific logging categories
logging enable

! Optional: Configure logging rate limiting
logging rate-limit 1000

! Example: Log configuration changes
archive
 log config
  logging enable
  notify syslog
```

### Cisco Nexus Syslog

```cisco
! Configure logging server
logging server 192.168.1.100 5 facility local0

! Set logging levels
logging level local0 6

! Optional: Configure VRF for logging
logging server 192.168.1.100 5 facility local0 vrf management
```

### Juniper JunOS Syslog

```junos
# Configure syslog destination
set system syslog host 192.168.1.100 any info
set system syslog host 192.168.1.100 facility-override local0

# Configure specific facilities
set system syslog host 192.168.1.100 kernel info
set system syslog host 192.168.1.100 daemon info
set system syslog host 192.168.1.100 authorization info
```

### Linux Syslog (rsyslog)

Edit `/etc/rsyslog.conf` or create `/etc/rsyslog.d/50-serviceradar.conf`:

```bash
# Forward all logs to ServiceRadar
*.* @192.168.1.100:514

# Forward specific facilities
local0.* @192.168.1.100:514
kern.* @192.168.1.100:514
auth.* @192.168.1.100:514

# Use TCP for reliable delivery (optional)
*.* @@192.168.1.100:514

# Forward with specific template
$template ServiceRadarFormat,"%timestamp% %hostname% %syslogtag% %msg%\n"
*.* @192.168.1.100:514;ServiceRadarFormat
```

Restart rsyslog:

```bash
sudo systemctl restart rsyslog
sudo systemctl status rsyslog
```

### Windows Event Log Forwarding

For Windows systems, use NXLog or similar:

#### NXLog Configuration

Edit `C:\Program Files (x86)\nxlog\conf\nxlog.conf`:

```xml
<Extension syslog>
    Module      xm_syslog
</Extension>

<Input eventlog>
    Module      im_msvistalog
    Query       <QueryList>\
                    <Query Id="0">\
                        <Select Path="Application">*</Select>\
                        <Select Path="System">*</Select>\
                        <Select Path="Security">*</Select>\
                    </Query>\
                </QueryList>
</Input>

<Output serviceradar>
    Module      om_udp
    Host        192.168.1.100
    Port        514
    Exec        to_syslog_bsd();
</Output>

<Route eventlog_to_serviceradar>
    Path        eventlog => serviceradar
</Route>
```

## SNMP Trap Configuration

Configure devices to send SNMP traps to ServiceRadar (UDP port 162):

### Cisco SNMP Traps

```cisco
! Configure trap destination
snmp-server host 192.168.1.100 version 2c monitoring

! Enable global trap settings
snmp-server enable traps

! Enable specific trap types
snmp-server enable traps snmp authentication linkdown linkup coldstart warmstart
snmp-server enable traps config
snmp-server enable traps entity
snmp-server enable traps envmon fan shutdown supply temperature
snmp-server enable traps flash insertion removal
snmp-server enable traps bgp
snmp-server enable traps ospf state-change
snmp-server enable traps power-ethernet group 1-2 police

! Optional: Configure trap source interface
snmp-server trap-source Loopback0
```

### SNMP v3 Traps

```cisco
! Configure v3 trap destination
snmp-server host 192.168.1.100 version 3 auth serviceradar-user

! Configure v3 user (if not already configured)
snmp-server user serviceradar-user serviceradar-group v3 auth sha serviceradar-auth-key
```

### Juniper SNMP Traps

```junos
# Configure trap destinations
set snmp trap-group serviceradar version v2
set snmp trap-group serviceradar targets 192.168.1.100

# Enable specific traps
set snmp trap-options source-address 10.0.0.1
```

### Linux SNMP Traps

Configure in `/etc/snmp/snmpd.conf`:

```bash
# Configure trap destination
trap2sink 192.168.1.100 monitoring

# Or for SNMP v3
trapsink 192.168.1.100 monitoring
```

## Device-Specific Configuration Examples

### Cisco ASA Firewall

```cisco
! SNMP Configuration
snmp-server community monitoring
snmp-server location "DMZ Firewall"
snmp-server contact "Security Team <security@company.com>"
snmp-server enable traps

! Syslog Configuration
logging enable
logging host inside 192.168.1.100
logging trap informational
logging facility 20
```

### Palo Alto Networks Firewall

```xml
<!-- Via CLI -->
set deviceconfig system snmp-setting community monitoring authorization read-only
set deviceconfig system snmp-setting location "Perimeter Firewall"
set deviceconfig system snmp-setting contact "Security Operations"

<!-- Syslog -->
set shared log-settings syslog serviceradar server 192.168.1.100 transport UDP port 514 facility LOG_USER
```

### F5 BIG-IP Load Balancer

```bash
# SNMP Configuration
tmsh modify sys snmp communities add { monitoring { community-name monitoring oid 1 access ro } }
tmsh modify sys snmp contact "Load Balancer Team <lb@company.com>"
tmsh modify sys snmp location "Load Balancer Farm"

# Syslog Configuration
tmsh create sys syslog remotesyslog serviceradar { host 192.168.1.100 remotereport enabled }
```

### VMware vSphere ESXi

```bash
# Enable SNMP via esxcli
esxcli system snmp set --communities monitoring
esxcli system snmp set --enable true
esxcli system snmp set --targets 192.168.1.100@161/monitoring

# Configure syslog
esxcli system syslog config set --loghost 192.168.1.100:514
esxcli system syslog reload
```

## Network Equipment by Vendor

### HPE/Aruba Switches

```arubaos
# SNMP Configuration
snmp-server community "monitoring" restricted
snmp-server location "Access Layer Switch"
snmp-server contact "Network Team"
snmp-server enable traps

# Syslog Configuration
logging 192.168.1.100
logging level warning
```

### Dell/Force10 Switches

```dell
! SNMP Configuration
snmp-server community monitoring ro
snmp-server location "Distribution Switch"
snmp-server contact "Network Operations"
snmp-server enable traps

! Syslog Configuration
logging 192.168.1.100
logging level informational
```

### Ubiquiti EdgeOS

```edgeos
# SNMP Configuration
set service snmp community monitoring authorization ro
set service snmp location "Edge Router"
set service snmp contact "Network Admin"

# Syslog Configuration
set system syslog host 192.168.1.100 facility all level info
```

## Security Considerations

### SNMP Security Best Practices

1. **Use SNMP v3** when possible for authentication and encryption
2. **Unique community strings** for each device class
3. **Read-only access** for monitoring (avoid RW communities)
4. **Source IP restrictions** using ACLs
5. **Regular credential rotation**

### Syslog Security

1. **Network segmentation** for logging traffic
2. **Encrypted transport** (TLS) for sensitive environments
3. **Log integrity** verification
4. **Access controls** on log data

### Network Access Controls

```cisco
! Example ACL for SNMP access
ip access-list extended SNMP-ACCESS
 permit udp host 192.168.1.100 any eq snmp
 permit udp host 192.168.1.100 any eq snmptrap
 deny udp any any eq snmp
 deny udp any any eq snmptrap

! Apply to interfaces
interface GigabitEthernet0/1
 ip access-group SNMP-ACCESS in
```

## Troubleshooting

### SNMP Troubleshooting

#### Test SNMP connectivity

```bash
# From ServiceRadar host
snmpwalk -v2c -c monitoring 192.168.1.1 1.3.6.1.2.1.1.1.0

# Test specific OIDs
snmpget -v2c -c monitoring 192.168.1.1 1.3.6.1.2.1.1.5.0  # System name
snmpget -v2c -c monitoring 192.168.1.1 1.3.6.1.2.1.1.1.0  # System description
```

#### Common SNMP issues

1. **Connection timeouts**: Check network connectivity, firewalls
2. **Authentication failures**: Verify community strings, SNMP version
3. **Permission denied**: Check SNMP access lists, IP restrictions
4. **No response**: Verify SNMP is enabled on target device

### Syslog Troubleshooting

#### Test syslog connectivity

```bash
# Generate test message
logger -n 192.168.1.100 -P 514 "Test message from $(hostname)"

# Use netcat to test UDP connectivity
echo "Test message" | nc -u 192.168.1.100 514

# Check if port is listening
netstat -tulnp | grep :514
```

#### Common syslog issues

1. **Messages not received**: Check network path, firewall rules
2. **Format issues**: Verify syslog format compatibility
3. **Dropped messages**: Check logging rate limits, buffer sizes
4. **Time synchronization**: Ensure NTP is configured

### ServiceRadar Verification

#### Check ServiceRadar collection

```bash
# View SNMP collection logs
docker-compose logs poller | grep -i snmp

# View syslog collection logs
docker-compose logs flowgger

# View trap collection logs
docker-compose logs trapd

# Query collected data
curl -X POST http://localhost/api/query \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <your-api-key>" \
  -d '{"query": "show devices", "limit": 10}'
```

## Advanced Configuration

### Custom SNMP OIDs

For custom monitoring, define additional OIDs in ServiceRadar:

```json
{
  "custom_oids": {
    "custom_temperature": "1.3.6.1.4.1.9.9.13.1.3.1.3",
    "custom_cpu_usage": "1.3.6.1.4.1.9.9.109.1.1.1.1.7",
    "custom_memory_used": "1.3.6.1.4.1.9.9.48.1.1.1.5"
  }
}
```

### Syslog Message Parsing

Configure custom syslog parsing rules:

```toml
# flowgger.toml
[input.syslog]
format = "rfc3164"

[output.rules]
cisco_ios = { pattern = "%CISCO-.*", transform = "parse_cisco_ios" }
linux_kernel = { pattern = "kernel:", transform = "parse_linux_kernel" }
```

### Integration with External Systems

#### Network Management Systems

Configure SNMP forwarding to other NMS:

```cisco
! Forward traps to multiple destinations
snmp-server host 192.168.1.100 monitoring  ! ServiceRadar
snmp-server host 192.168.1.101 monitoring  ! Primary NMS
snmp-server host 192.168.1.102 monitoring  ! Backup NMS
```

#### SIEM Integration

Forward logs to both ServiceRadar and SIEM:

```bash
# rsyslog configuration for dual forwarding
*.* @192.168.1.100:514  # ServiceRadar
*.* @192.168.1.200:514  # SIEM
```

This comprehensive device configuration guide should help users successfully configure their network devices to send monitoring data to ServiceRadar through various protocols.