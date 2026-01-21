# Tasks: Interface UI Improvements

## 1. Interfaces Table Enhancements

- [x] 1.1 Add row selection checkboxes to interfaces table
- [x] 1.2 Implement select-all/deselect-all functionality
- [x] 1.3 Add bulk edit toolbar that appears when rows are selected
- [x] 1.4 Add favorite/star icon column with click-to-toggle
- [ ] 1.5 Persist interface favorite state to backend
- [x] 1.6 Add interface ID column to table
- [x] 1.7 Add metrics collection indicator icon (clickable)
- [x] 1.8 Create interface type mapping module in Elixir (ethernetCsmacd -> Ethernet, etc.)
- [x] 1.9 Apply human-readable type mapping in interfaces table
- [x] 1.10 Improve status column with colorized labels/badges
- [x] 1.11 Ensure status indicators are color-blind accessible (use icons + colors)
- [x] 1.12 Fix nil display in status column

## 2. Interface Details Screen

- [x] 2.1 Create interface details LiveView at `/devices/:device_id/interfaces/:interface_id`
- [x] 2.2 Display interface properties (name, description, type, speed, MAC, IPs)
- [x] 2.3 Display OID information on interface details page
- [ ] 2.4 Add metrics collection enable/disable toggle
- [ ] 2.5 Implement backend endpoint for toggling metrics collection
- [x] 2.6 Show interface status with same colorized styling as table

## 3. Bulk Edit Feature

- [ ] 3.1 Create bulk edit modal/slideout component
- [ ] 3.2 Support bulk enable/disable metrics collection
- [ ] 3.3 Support bulk favorite/unfavorite
- [ ] 3.4 Support bulk tag assignment to interfaces
- [ ] 3.5 Implement backend bulk update endpoint

## 4. Metrics Visualization for Favorited Interfaces

- [ ] 4.1 Query favorited interfaces with metrics collection enabled
- [ ] 4.2 Add metrics visualization section above interfaces table
- [ ] 4.3 Implement auto-viz component that selects chart type based on metric type
- [ ] 4.4 Render gauge metrics as gauge charts
- [ ] 4.5 Render counter metrics as line/area charts
- [ ] 4.6 Handle empty state when no favorited interfaces have metrics

## 5. Threshold and Alert Configuration

- [ ] 5.1 Add threshold configuration UI on interface details page
- [ ] 5.2 Support threshold on utilization metrics (bandwidth, errors, etc.)
- [ ] 5.3 Implement threshold persistence in backend
- [ ] 5.4 Generate events when threshold conditions are met
- [ ] 5.5 Integrate alert editor component from settings page
- [ ] 5.6 Support alert creation on interface threshold events
- [ ] 5.7 Configure alert parameters (threshold exceeded for X duration)

## 6. Backend Ash Resources

- [ ] 6.1 Add `favorited` boolean attribute to interface resource
- [ ] 6.2 Add `metrics_enabled` boolean attribute to interface resource
- [ ] 6.3 Create InterfaceThreshold Ash resource
- [ ] 6.4 Create migration for new interface fields
- [ ] 6.5 Add SRQL support for querying favorited interfaces

## 7. Testing

- [ ] 7.1 Add LiveView tests for interface details page
- [ ] 7.2 Add tests for bulk edit functionality
- [ ] 7.3 Add tests for interface type mapping
- [ ] 7.4 Add tests for threshold event generation
