import {mountServiceAvailabilityNoc} from "./service_availability_noc"
import {mountSecurityFindings} from "./security_findings"
import {mountEndpointInventory} from "./endpoint_inventory"

export const builtInDashboardRenderers = {
  service_availability_noc: mountServiceAvailabilityNoc,
  "service-availability-noc": mountServiceAvailabilityNoc,
  security_findings: mountSecurityFindings,
  "security-findings": mountSecurityFindings,
  endpoint_inventory: mountEndpointInventory,
  "endpoint-inventory": mountEndpointInventory,
}
