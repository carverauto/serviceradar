## 1. Data Model And Queries
- [ ] 1.1 Define attributed-flow page query contract: attributed-only default, raw/unmatched mode, pagination, sorting, and filters
- [ ] 1.2 Include collector agent identity in result rows and detail payloads
- [ ] 1.3 Add or reuse reverse-DNS/hostname enrichment lookup for flow endpoint display
- [ ] 1.4 Add or reuse CTI/IOC match lookup for flow endpoint/domain indicators
- [ ] 1.5 Add tests for count/filter consistency between summary cards and rows

## 2. Attributed Flows UI
- [ ] 2.1 Replace unconditional refresh with a logs-style Live toggle
- [ ] 2.2 Add pagination controls and pause Live on manual navigation/filter changes
- [ ] 2.3 Make summary cards clickable filters
- [ ] 2.4 Redesign the table to avoid horizontal scrolling at desktop widths
- [ ] 2.5 Render bytes as human-readable units while preserving exact values in details
- [ ] 2.6 Add row click detail modal or detail route with raw NetFlow and attribution context
- [ ] 2.7 Fix the topbar title to show "Attributed Flows"

## 3. NetFlow Map Integration
- [ ] 3.1 Annotate map flows with attribution state when process context exists
- [ ] 3.2 Add map drilldown to the shared flow detail view
- [ ] 3.3 Show process, agent, and IOC summary in map hover/selection UI without cluttering the map

## 4. Verification
- [ ] 4.1 Add LiveView tests for pagination, Live toggle, card filters, and row detail behavior
- [ ] 4.2 Add query tests for attributed/unmatched counts and enrichment joins
- [ ] 4.3 Validate responsive desktop/mobile layouts with Playwright screenshots
