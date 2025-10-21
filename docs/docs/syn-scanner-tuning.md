---
sidebar_position: 7
title: Safely Tuning Linux for High-Speed SYN Scans
---

This guide helps you run fast TCP SYN scans safely by isolating the scanner's traffic from the kernel's connection tracking system (`conntrack`). This prevents the scanner from overwhelming the firewall and breaking other network applications on the server.

<div class="warning">
  <strong>WARNING: Incorrectly applying these rules can disrupt your server's network connectivity.</strong>
</div>

### When to Use This Guide

*   You are running the SYN scanner on a Linux host and want to achieve a high packet rate (e.g., >10,000 pps).
*   You see `nf_conntrack: table full` messages in `dmesg` or are experiencing firewall/NAT performance issues during scans.
*   You want to prevent the scanner from interfering with other applications on the same machine.

---

### **Part 1: Tuning the *Scanner* Host**

This is the most common scenario. The goal is to prevent the high volume of outgoing SYN packets from the scanner from filling up the *scanner's own* connection tracking table.

#### The Strategy: Isolate Scanner Traffic

The scanner is designed to use a dedicated range of source ports for its outgoing packets. We will create a firewall rule that matches traffic from this specific port range and tells the kernel not to track it. All other traffic (from applications using standard "ephemeral" ports) will be tracked normally.

**Step 1: Reserve a Dedicated Port Range for the Scanner**

First, we must tell the Linux kernel to reserve a block of ports exclusively for the scanner. This prevents other applications from accidentally using them. A range of 10,000-20,000 ports is a good starting point.

```bash
# Reserve ports 40000-59999 for the scanner.
# This command makes the change permanent and applies it immediately.
sudo sysctl -w net.ipv4.ip_local_reserved_ports="40000-59999"
echo "net.ipv4.ip_local_reserved_ports = 40000-59999" | sudo tee /etc/sysctl.d/99-scanner-ports.conf
```
> The scanner code provided is designed to automatically detect and use large reserved port ranges, so no application changes are needed after this step.

**Step 2: Apply the Correct `NOTRACK` Firewall Rule**

Now, create the firewall rule that exempts this specific traffic from connection tracking.

#### **Using `nftables` (Recommended)**

```bash
# 1. Create the 'raw' table if it doesn't exist
sudo nft add table inet raw

# 2. Create the 'output' chain for outgoing traffic
# The priority -300 ensures this hook runs before other firewall processing.
sudo nft add chain inet raw output { type route hook output priority -300 \; }

# 3. Add the correctly scoped NOTRACK rule.
#    - Replace <YOUR_SCANNER_IP> with the source IP of your server.
#    - Use the same port range you reserved in Step 1.
sudo nft add rule inet raw output ip saddr <YOUR_SCANNER_IP> tcp sport 40000-59999 tcp flags syn notrack
```

#### **Using `iptables` (Legacy)**

If you are still using `iptables`, the equivalent commands are:

```bash
# 1. Add the rule to the raw OUTPUT chain.
#    - Replace <YOUR_SCANNER_IP> with the source IP of your server.
#    - Use the same port range you reserved in Step 1.
sudo iptables -t raw -A OUTPUT -s <YOUR_SCANNER_IP> -p tcp -m multiport --sports 40000:59999 --syn -j NOTRACK
```

With these rules, your SYN scanner can run at maximum speed without affecting the rest of the server's network operations.

---

### **Part 2: Protecting a *Target* Host (Optional)**

This is a different use case. These rules would be applied to a server (e.g., a web server) to protect it from being overwhelmed by an inbound SYN scan from another machine.

<div class="danger">
  <strong>DANGER: Applying <code>NOTRACK</code> to incoming traffic effectively disables the stateful nature of your firewall for that traffic.</strong>
  <p>This can break certain protocols (like FTP) and bypass security features that rely on connection tracking. Only apply these rules if you are protecting a simple service (like a web server) and understand the security implications.</p>
</div>

#### **Using `nftables`**

```bash
# 1. Create the 'raw' table and 'prerouting' chain
sudo nft add table inet raw
sudo nft add chain inet raw prerouting { type filter hook prerouting priority -300 \; }

# 2. Add the NOTRACK rule for incoming SYNs to a specific IP.
#    Replace <YOUR_SERVER_IP> with the public IP being scanned.
sudo nft add rule inet raw prerouting ip daddr <YOUR_SERVER_IP> tcp flags syn notrack
```

#### **Using `iptables`**

```bash
# Add the rule to the raw PREROUTING chain.
# Replace <YOUR_SERVER_IP> with the public IP being scanned.
sudo iptables -t raw -A PREROUTING -d <YOUR_SERVER_IP> -p tcp --syn -j NOTRACK
```

---

### **Alternative: Tuning Conntrack Capacity**

If you cannot use `NOTRACK` rules, your other option is to increase the size of the connection tracking table and lower the timeouts for unanswered SYNs. This is less efficient but can help mitigate table exhaustion.

*   **Increase Capacity:**
    *   `sudo sysctl -w net.netfilter.nf_conntrack_max=524288` (Adjust based on available memory)

*   **Lower Timeouts for Unestablished Connections:**
    *   `sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_sent=30`
    *   `sudo sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30`

Remember to save these settings to a file in `/etc/sysctl.d/` to make them permanent.