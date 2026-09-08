# Proposal: 2026 Pitch Deck Update

## Goal
Update the ServiceRadar pitch deck to reflect the current feature set, architectural maturity, and enterprise positioning.

## Context
Since the original pitch deck was created, ServiceRadar has evolved from a basic distributed monitoring tool into a comprehensive platform for heterogeneous network management, security context fabric, and advanced edge observability. 

The original slides overemphasize SRQL syntax and basic service checks, while missing our most significant competitive differentiators:
- **FabricView Topology:** A backend-authoritative, high-fidelity graph using Apache AGE.
- **WASM Plugin Ecosystem:** A sandboxed extension model using the wazero WASI runtime.
- **Deepcausality Engine:** Causal security and operational context across the entire fabric.
- **Advanced WiFi & IPTV:** Specialised management for high-density wireless and large-scale camera fleets (6,000+ targets).
- **Unified Logic:** Bridging the gap between siloed NCM, SIEM, and monitoring tools.
- **Ansible Integration:** Upcoming server management and automation directly from the SR console.
- **Postgres-Centric Analytics:** A unified, cloud-native data stack using Apache AGE (Graph), TimescaleDB (Time-series), PostGIS (Spatial), pgvector (AI/LLM), and ParadeDB (Search/Analytics).

## Proposed Changes
1. **Redefine the Value Proposition:** Focus on "Bridging the Silos" and "Total Visibility for the Heterogeneous Enterprise."
2. **De-emphasize SRQL Syntax:** Move SRQL from a "primary feature" to an "enabler" for natural language and LLM-driven interrogation.
3. **Highlight Topology (GodView):** Showcase the move from simple connectivity to authoritative, render-ready graphs that handle mixed evidence (LLDP/CDP/SNMP) using Apache AGE.
4. **Introduce the WASM Plugin SDK:** Emphasize the ease of extensibility and the safety of the sandboxed runtime.
5. **Showcase Enterprise Vertical Offerings:** Specifically mention the high-density WiFi survey tools (PostGIS-backed) and IPTV/NVR management capabilities.
6. **Causal Security Context:** Highlight the use of `deep_causality` to manage context across the entire network fabric.
7. **Competitive Comparison:** Directly address incumbents (OpenText NNM, PRTG, Solarwinds, Nagios) and our "Zero-Blind-Spot" edge architecture.
8. **Automation & Management:** Introduce upcoming Ansible integration for direct server management from the SR console.
10. **Slidev Upgrade:** Upgrade to Slidev v52.14.1+ for improved rendering, performance, and features.

## Success Criteria
- The pitch deck is high-level, impactful, and visually compelling.
- Technical details (WASM, AGE, Deepcausality) are presented as value-drivers, not just jargon.
- The platform's ability to replace multiple legacy silos is clear.
- The investor narrative flows from "Current Siloed Fragmentation" to "ServiceRadar Unified Fabric."
