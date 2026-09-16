## ADDED Requirements
### Requirement: Disk capacity is forecast per mount point
The system SHALL maintain an hourly continuous aggregate of disk usage keyed by device, series key and mount point, SHALL expose it through a dedicated SRQL entity, and SHALL forecast disk capacity per (device, mount point) with the device as the resource id and the mount point in the resource label.

#### Scenario: One full filesystem is not diluted by its neighbours
- **GIVEN** a host whose root filesystem is flat at 20 percent and whose data mount grows toward 100 percent
- **WHEN** the capacity worker runs
- **THEN** the data mount has its own forecast row keyed by device and mount
- **AND** the root filesystem has a separate row that records no projected exhaustion

#### Scenario: Device pages still find their forecasts
- **GIVEN** per-mount forecast rows for a device
- **WHEN** the device page queries capacity forecasts by resource id
- **THEN** every mount's row for that device is returned
