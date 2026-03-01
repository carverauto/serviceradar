## ADDED Requirements

### Requirement: WiFi channel analysis
The system SHALL analyze AP radio channel assignments to detect interference and recommend optimal channel configurations.

#### Scenario: Co-channel interference detection
- **GIVEN** two or more APs operating on the same channel within RF proximity
- **WHEN** channel analysis runs
- **THEN** the system SHALL flag co-channel interference with severity based on signal overlap
- **AND** identify the affected AP pairs

#### Scenario: Adjacent-channel interference detection on 2.4 GHz
- **GIVEN** APs on 2.4 GHz channels that are less than 5 channels apart (e.g., channels 1 and 3)
- **WHEN** channel analysis runs
- **THEN** the system SHALL flag adjacent-channel interference
- **AND** recommend non-overlapping channels (1, 6, 11 for 20 MHz width)

#### Scenario: Channel recommendation generation
- **GIVEN** a set of APs with current channel assignments and utilization data
- **WHEN** channel analysis runs
- **THEN** the system SHALL generate per-AP channel recommendations
- **AND** recommendations SHALL respect regulatory domain constraints
- **AND** recommendations SHALL consider AP hardware capabilities (supported channels/widths)
- **AND** recommendations SHALL minimize co-channel and adjacent-channel overlap

### Requirement: AP load balancing analysis
The system SHALL analyze client distribution across access points to detect load imbalances and recommend corrections.

#### Scenario: Load imbalance detection
- **GIVEN** multiple APs serving the same area/SSID
- **WHEN** load analysis runs
- **THEN** the system SHALL calculate client count and utilization per AP
- **AND** flag load imbalance when any AP exceeds 2x the average client count or utilization percentage

#### Scenario: Airtime utilization distribution
- **GIVEN** AP radio utilization data collected from controller API
- **WHEN** load analysis runs
- **THEN** the system SHALL display per-AP airtime utilization as a percentage
- **AND** identify APs approaching capacity (>70% utilization)

### Requirement: Band steering analysis
The system SHALL analyze client distribution across frequency bands (2.4 GHz, 5 GHz, 6 GHz) and detect suboptimal band usage.

#### Scenario: High 2.4 GHz concentration warning
- **GIVEN** an SSID serving clients on both 2.4 GHz and 5 GHz
- **WHEN** band analysis runs and >40% of clients are on 2.4 GHz
- **THEN** the system SHALL flag high 2.4 GHz concentration
- **AND** recommend enabling or tuning band steering

#### Scenario: Band distribution per SSID
- **GIVEN** wireless client observations across multiple bands
- **WHEN** band analysis runs
- **THEN** the system SHALL calculate the percentage of clients on each band per SSID
- **AND** present the distribution for operator review

### Requirement: Wireless client statistics
The system SHALL provide comprehensive statistics for wireless clients including signal quality, WiFi generation, and connection trends.

#### Scenario: WiFi generation breakdown
- **GIVEN** wireless client observations with WiFi generation data
- **WHEN** client statistics are queried
- **THEN** the system SHALL show the count and percentage of clients by WiFi generation (802.11a/n/ac/ax/be)
- **AND** identify legacy clients (802.11a/n only) that may impact airtime efficiency

#### Scenario: Per-client signal history
- **GIVEN** a specific wireless client MAC address
- **WHEN** signal history is queried
- **THEN** the system SHALL return time-series RSSI data from `wireless_client_observations`
- **AND** include associated AP, channel, and TX/RX rate at each observation point

#### Scenario: Client connection quality scoring
- **GIVEN** a wireless client's recent observations
- **WHEN** quality scoring runs
- **THEN** the system SHALL compute a composite score from signal strength, TX/RX rate relative to capability, and connection stability
- **AND** classify as Good (>70), Fair (40-70), or Poor (<40)

### Requirement: Roaming analysis
The system SHALL track wireless client roaming between access points and detect roaming anomalies.

#### Scenario: Roaming event detection
- **GIVEN** consecutive observations of a client associated with different APs
- **WHEN** roaming analysis runs
- **THEN** the system SHALL record a roaming event with: timestamp, client MAC, from_ap, to_ap, signal_before, signal_after

#### Scenario: Sticky client detection
- **GIVEN** a client with signal strength below -75 dBm on its current AP
- **AND** a nearby AP where the client would have better signal (based on other clients' observations)
- **WHEN** roaming analysis runs
- **THEN** the system SHALL flag the client as "sticky" (not roaming when it should)

#### Scenario: Excessive roaming detection
- **GIVEN** a client that roams more than 10 times per hour
- **WHEN** roaming analysis runs
- **THEN** the system SHALL flag the client as an "excessive roamer"
- **AND** indicate the APs involved in the roaming pattern

### Requirement: WiFi site health scoring
The system SHALL compute a composite site health score (0-100) that reflects overall wireless network quality across multiple dimensions.

#### Scenario: Health score calculation
- **WHEN** the site health scoring job runs
- **THEN** the system SHALL compute a score from weighted dimensions:
  - Coverage quality (25%): percentage of clients with signal above -70 dBm
  - Capacity headroom (20%): inverse of average AP utilization
  - Interference level (20%): inverse of co-channel interference severity
  - Roaming health (15%): ratio of successful roams to sticky/excessive roaming events
  - Client satisfaction (20%): average client connection quality score
- **AND** persist the score as a `WiFiSiteHealth` snapshot in a hypertable

#### Scenario: Health score regression detection
- **GIVEN** site health scores tracked over time
- **WHEN** the current score drops more than 15 points below the 7-day rolling average
- **THEN** the system SHALL generate a health regression alert
- **AND** identify which dimensions contributed to the decline

### Requirement: Airtime fairness analysis
The system SHALL analyze airtime consumption patterns to detect legacy devices disproportionately consuming wireless capacity.

#### Scenario: Legacy client airtime impact
- **GIVEN** a mix of legacy (802.11n) and modern (802.11ac/ax) clients on the same AP radio
- **WHEN** airtime fairness analysis runs
- **THEN** the system SHALL estimate relative airtime consumption based on client data rates
- **AND** flag when legacy clients are estimated to consume more than their proportional share of airtime

#### Scenario: Isolation recommendation
- **GIVEN** legacy clients detected consuming disproportionate airtime on a dual-band AP
- **WHEN** airtime fairness analysis generates recommendations
- **THEN** the system SHALL recommend isolating legacy clients to a dedicated 2.4 GHz SSID
- **AND** quantify the estimated airtime savings

### Requirement: TX power analysis
The system SHALL analyze AP transmit power settings and recommend adjustments based on coverage and interference data.

#### Scenario: Excessive TX power detection
- **GIVEN** an AP with TX power higher than needed to cover its area (indicated by many clients with signal > -50 dBm)
- **WHEN** TX power analysis runs
- **THEN** the system SHALL recommend reducing TX power
- **AND** explain that excessive power increases co-channel interference range

#### Scenario: Insufficient TX power detection
- **GIVEN** an AP where >30% of clients have signal below -75 dBm
- **WHEN** TX power analysis runs
- **THEN** the system SHALL flag potential insufficient coverage
- **AND** recommend increasing TX power or adding an additional AP

### Requirement: WiFi analytics dashboard
The system SHALL provide a LiveView dashboard for visualizing WiFi analytics data including channel maps, client statistics, load balance views, and site health.

#### Scenario: Channel map visualization
- **GIVEN** AP radio state data with channel assignments
- **WHEN** a user views the WiFi analytics dashboard
- **THEN** the system SHALL display which APs are on which channels
- **AND** visually indicate channel overlap and interference

#### Scenario: Client statistics table
- **GIVEN** wireless client observations
- **WHEN** a user views the client statistics tab
- **THEN** the system SHALL display a sortable, filterable table of wireless clients
- **AND** include columns: client name/MAC, AP, SSID, signal (dBm), WiFi generation, band, TX/RX rate, connection quality score

#### Scenario: Site health scorecard
- **GIVEN** WiFi site health scores over time
- **WHEN** a user views the site health tab
- **THEN** the system SHALL display the current score with dimension breakdown
- **AND** show score trend over the selected time range
