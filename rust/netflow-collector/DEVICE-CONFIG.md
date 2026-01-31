# NetFlow Device Configuration Quick Reference

Quick copy-paste configurations for common network devices to export NetFlow/IPFIX to ServiceRadar.

**Replace `<COLLECTOR-IP>` with your ServiceRadar collector IP address.**

**Default port:** UDP 2055 (configurable in collector config)

---

## Table of Contents

- [Cisco IOS/IOS-XE](#cisco-iosios-xe)
- [Cisco NXOS](#cisco-nxos)
- [Cisco ASA](#cisco-asa)
- [Juniper Junos](#juniper-junos)
- [MikroTik RouterOS](#mikrotik-routeros)
- [Fortinet FortiGate](#fortinet-fortigate)
- [Palo Alto Networks](#palo-alto-networks)
- [VyOS](#vyos)
- [pfSense/OPNsense](#pfenseopnsense)
- [Arista EOS](#arista-eos)
- [HPE/Aruba](#hpearuba)
- [Huawei](#huawei)
- [Verification Commands](#verification-commands)

---

## Cisco IOS/IOS-XE

**NetFlow v9 (Recommended):**

```cisco
! Configure flow exporter
flow exporter SERVICERADAR-COLLECTOR
  destination <COLLECTOR-IP>
  transport udp 2055
  source Loopback0
  template data timeout 60
  option application-table timeout 60

! Configure flow record
flow record SERVICERADAR-RECORD
  match ipv4 protocol
  match ipv4 source address
  match ipv4 destination address
  match transport source-port
  match transport destination-port
  match interface input
  collect counter bytes
  collect counter packets
  collect timestamp sys-uptime first
  collect timestamp sys-uptime last
  collect interface output

! Configure flow monitor
flow monitor SERVICERADAR-MONITOR
  exporter SERVICERADAR-COLLECTOR
  cache timeout active 60
  cache timeout inactive 15
  record SERVICERADAR-RECORD

! Apply to interfaces
interface GigabitEthernet0/0
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output

interface GigabitEthernet0/1
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output
```

**NetFlow v5 (Legacy):**

```cisco
ip flow-export destination <COLLECTOR-IP> 2055
ip flow-export source Loopback0
ip flow-export version 5

interface GigabitEthernet0/0
  ip route-cache flow

interface GigabitEthernet0/1
  ip route-cache flow
```

**Verification:**
```cisco
show flow exporter SERVICERADAR-COLLECTOR
show flow monitor SERVICERADAR-MONITOR statistics
show flow interface
```

---

## Cisco NXOS

**NetFlow v9:**

```cisco
feature netflow

! Configure flow exporter
flow exporter SERVICERADAR
  destination <COLLECTOR-IP> use-vrf management
  transport udp 2055
  source mgmt0
  version 9

! Configure flow record
flow record SERVICERADAR-RECORD
  match ipv4 source address
  match ipv4 destination address
  match ip protocol
  match ip tos
  match transport source-port
  match transport destination-port
  collect counter bytes
  collect counter packets
  collect timestamp sys-uptime first
  collect timestamp sys-uptime last

! Configure flow monitor
flow monitor SERVICERADAR-MONITOR
  record SERVICERADAR-RECORD
  exporter SERVICERADAR

! Apply to interfaces
interface Ethernet1/1
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output

interface Ethernet1/2
  ip flow monitor SERVICERADAR-MONITOR input
  ip flow monitor SERVICERADAR-MONITOR output
```

**Verification:**
```cisco
show flow exporter SERVICERADAR
show flow monitor SERVICERADAR-MONITOR
show flow interface
```

---

## Cisco ASA

**NetFlow v9:**

```cisco
flow-export destination inside <COLLECTOR-IP> 2055
flow-export template timeout-rate 60
flow-export delay flow-create 60

policy-map global_policy
  class class-default
    flow-export event-type all destination <COLLECTOR-IP>
```

**Verification:**
```cisco
show flow-export counters
show run flow-export
```

---

## Juniper Junos

**IPFIX:**

```juniper
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE flow-active-timeout 60
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE flow-inactive-timeout 15
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE template-refresh-rate packets 30
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE template-refresh-rate seconds 60
set services flow-monitoring version-ipfix template SERVICERADAR-TEMPLATE ipv4-template

set forwarding-options sampling instance SERVICERADAR-INSTANCE
set forwarding-options sampling instance SERVICERADAR-INSTANCE family inet output flow-server <COLLECTOR-IP> port 2055
set forwarding-options sampling instance SERVICERADAR-INSTANCE family inet output flow-server <COLLECTOR-IP> version-ipfix template SERVICERADAR-TEMPLATE
set forwarding-options sampling instance SERVICERADAR-INSTANCE family inet output inline-jflow source-address <ROUTER-IP>

! Apply to interfaces
set interfaces ge-0/0/0 unit 0 family inet sampling input
set interfaces ge-0/0/0 unit 0 family inet sampling output
set interfaces ge-0/0/1 unit 0 family inet sampling input
set interfaces ge-0/0/1 unit 0 family inet sampling output
```

**Verification:**
```juniper
show services flow-monitoring
show forwarding-options sampling
```

---

## MikroTik RouterOS

**NetFlow v9:**

```mikrotik
/ip traffic-flow
set enabled=yes
set interfaces=ether1,ether2,ether3
set cache-entries=16k
set active-flow-timeout=1m
set inactive-flow-timeout=15s

/ip traffic-flow target
add address=<COLLECTOR-IP>:2055 version=9
```

**Verification:**
```mikrotik
/ip traffic-flow print
/ip traffic-flow target print
```

---

## Fortinet FortiGate

**NetFlow v9:**

```fortinet
config system netflow
    set collector-ip <COLLECTOR-IP>
    set collector-port 2055
    set source-ip 0.0.0.0
    set active-flow-timeout 60
    set inactive-flow-timeout 15
    set template-tx-timeout 60
    set template-tx-counter 20
end

config system interface
    edit "port1"
        set netflow-sampler both
    next
    edit "port2"
        set netflow-sampler both
    next
end
```

**Verification:**
```fortinet
get system netflow
diagnose netflow collector-info
```

---

## Palo Alto Networks

**NetFlow v9:**

```paloalto
set deviceconfig system netflow-collector SERVICERADAR server <COLLECTOR-IP>
set deviceconfig system netflow-collector SERVICERADAR port 2055
set deviceconfig system netflow-collector SERVICERADAR transport udp

set network profiles netflow SERVICERADAR-PROFILE
set network profiles netflow SERVICERADAR-PROFILE server SERVICERADAR
set network profiles netflow SERVICERADAR-PROFILE template-refresh-rate 60
set network profiles netflow SERVICERADAR-PROFILE active-timeout 60
set network profiles netflow SERVICERADAR-PROFILE inactive-timeout 15

! Apply to zone protection profile
set zone-protection-profile default-zone-protection netflow SERVICERADAR-PROFILE

! Or apply to security policy
set rulebase security rules ALLOW-ALL actions netflow SERVICERADAR-PROFILE
```

**Verification:**
```paloalto
show netflow collector
show netflow profile
```

---

## VyOS

**NetFlow v9:**

```vyos
set system flow-accounting interface eth0
set system flow-accounting interface eth1
set system flow-accounting interface eth2

set system flow-accounting netflow server <COLLECTOR-IP> port 2055
set system flow-accounting netflow version 9
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-generic 15
set system flow-accounting netflow timeout max-active-life 60

commit
save
```

**Verification:**
```vyos
show flow-accounting
```

---

## pfSense/OPNsense

**softflowd (via Package Manager):**

1. Install softflowd package via web GUI: System → Package Manager
2. Configure: Services → softflowd

**Manual Configuration:**

```bash
# Edit /usr/local/etc/softflowd.conf
interface: em0
host: <COLLECTOR-IP>
port: 2055
version: 9
timeout:
  general: 60
  tcp: 300
  tcp.rst: 120
  tcp.fin: 120
  udp: 60
  icmp: 60

# Start service
/usr/local/etc/rc.d/softflowd start
```

**Verification:**
```bash
softflowctl -c /var/run/softflowd.ctl statistics
```

---

## Arista EOS

**sFlow (converts to NetFlow):**

```arista
! Configure sFlow
sflow sample 16384
sflow destination <COLLECTOR-IP>
sflow source-interface Management1
sflow run

! Apply to interfaces
interface Ethernet1
  sflow enable

interface Ethernet2
  sflow enable
```

**Note:** Arista primarily uses sFlow. Use sFlow-to-NetFlow converter if needed, or use sFlow collector directly.

**Verification:**
```arista
show sflow
```

---

## HPE/Aruba

**HPE Comware (NetFlow v9):**

```comware
ip netstream export version 9
ip netstream export source loopback 0
ip netstream export host <COLLECTOR-IP> 2055
ip netstream timeout active 1
ip netstream timeout inactive 15

interface GigabitEthernet1/0/1
  ip netstream inbound
  ip netstream outbound

interface GigabitEthernet1/0/2
  ip netstream inbound
  ip netstream outbound
```

**ArubaOS-Switch (sFlow):**

```aruba
sflow 1 destination <COLLECTOR-IP> 2055
sflow 1 polling ethernet 1/1/1 30
sflow 1 sampling ethernet 1/1/1 512
sflow 1 enable
```

**Verification (Comware):**
```comware
display ip netstream export
display ip netstream interface
```

---

## Huawei

**NetStream (NetFlow v9 equivalent):**

```huawei
ip netstream export version 9
ip netstream export source loopback 0
ip netstream export host <COLLECTOR-IP> 2055
ip netstream timeout active 1
ip netstream timeout inactive 15

interface GigabitEthernet0/0/1
  ip netstream inbound
  ip netstream outbound

interface GigabitEthernet0/0/2
  ip netstream inbound
  ip netstream outbound
```

**Verification:**
```huawei
display ip netstream export
display ip netstream interface
```

---

## Verification Commands

### Check Flow Export on Device

**Cisco IOS/IOS-XE:**
```cisco
show flow exporter statistics
show flow monitor statistics
show flow interface
```

**Cisco NXOS:**
```cisco
show flow exporter SERVICERADAR statistics
show flow monitor SERVICERADAR-MONITOR
```

**Juniper:**
```juniper
show services flow-monitoring flow-server
show services flow-monitoring version-ipfix
```

**MikroTik:**
```mikrotik
/ip traffic-flow monitor
```

### Verify Flows Received at Collector

**On Collector Host:**

```bash
# Check UDP packets arriving
sudo tcpdump -i any -n port 2055 -c 10
# Should show: IP <device-ip>.xxxxx > <collector-ip>.2055: UDP, length 1480

# Check collector logs
docker logs netflow-collector | grep "Received.*bytes from <device-ip>"
kubectl logs -l app=netflow-collector | grep "Received.*bytes from <device-ip>"

# Check template learned
docker logs netflow-collector | grep "Template learned"

# Check flows in database
psql -c "SELECT COUNT(*) FROM ocsf_network_activity WHERE time > NOW() - INTERVAL '5 minutes';"
```

---

## Common Configuration Parameters

**Recommended Settings:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Active Timeout** | 60 seconds | Export flows after 60s even if still active |
| **Inactive Timeout** | 15 seconds | Export flows after 15s of no packets |
| **Template Refresh** | 60 seconds | Re-send template every 60s |
| **Source Interface** | Loopback or Management | Consistent source IP |
| **Version** | 9 or IPFIX | Recommended (v5 for legacy only) |
| **Port** | 2055/udp | ServiceRadar default |

**Sampling Ratios** (for high-traffic interfaces):

- **Low traffic** (< 100 Mbps): 1:1 (no sampling)
- **Medium traffic** (100 Mbps - 1 Gbps): 1:100
- **High traffic** (> 1 Gbps): 1:1000

---

## Firewall Rules

**Allow on collector host:**

```bash
# iptables (Linux)
sudo iptables -A INPUT -p udp --dport 2055 -s <device-ip> -j ACCEPT

# UFW (Ubuntu)
sudo ufw allow from <device-ip> to any port 2055 proto udp

# firewalld (RHEL/CentOS)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<device-ip>" port port="2055" protocol="udp" accept'
sudo firewall-cmd --reload
```

**Cloud Security Groups:**

- **AWS**: Allow UDP 2055 inbound from device IPs
- **Azure**: Allow UDP 2055 in Network Security Group
- **GCP**: Allow UDP 2055 in firewall rules

---

## Troubleshooting

### No Flows Appearing

1. **Verify device config**: Run verification commands above
2. **Check network path**: `traceroute <collector-ip>` from device
3. **Test UDP connectivity**: `nc -u <collector-ip> 2055` (send test packet)
4. **Check firewall**: Verify UDP 2055 allowed
5. **Check collector logs**: Look for "Received X bytes from <device-ip>"

### Template Issues

- **Missing templates**: Normal on startup, wait 60 seconds for router to re-send
- **Template collisions**: Upgrade to collector 0.8.0+ (AutoScopedParser)
- **Invalid templates**: Check device NetFlow version compatibility

### High Load

- **Enable sampling**: Configure sampling ratio on device
- **Reduce interfaces**: Only monitor critical interfaces
- **Increase collector resources**: More CPU/memory
- **Use multiple collectors**: Load balance across collectors

---

## Additional Resources

- [Full NetFlow Guide](../../docs/docs/netflow.md)
- [Troubleshooting](../../docs/docs/troubleshooting-guide.md#netflow)
- [Testing Guide](./TESTING.md)
- [Changelog](./CHANGELOG.md)

---

**Support:**
- Report issues: https://github.com/carverauto/serviceradar/issues
- Documentation: https://serviceradar.io/docs/netflow
