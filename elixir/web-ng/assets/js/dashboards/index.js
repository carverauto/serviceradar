import {mountServiceAvailabilityNoc} from "./service_availability_noc"
import {mountSecurityFindings} from "./security_findings"
import {mountEndpointInventory} from "./endpoint_inventory"
import {mountNetworkPerformance} from "./network_performance"
import {mountWebRum} from "./web_rum"

export const builtInDashboardRenderers = {
  service_availability_noc: mountServiceAvailabilityNoc,
  "service-availability-noc": mountServiceAvailabilityNoc,
  security_findings: mountSecurityFindings,
  "security-findings": mountSecurityFindings,
  endpoint_inventory: mountEndpointInventory,
  "endpoint-inventory": mountEndpointInventory,
  network_performance: mountNetworkPerformance,
  "network-performance": mountNetworkPerformance,
  web_rum: mountWebRum,
  "web-rum": mountWebRum,
}
