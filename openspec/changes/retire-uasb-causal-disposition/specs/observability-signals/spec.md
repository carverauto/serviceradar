# observability-signals — tiered anomaly disposition

## ADDED Requirements

### Requirement: Detection Is Cause-Agnostic

Anomaly **detection** SHALL flag a per-series deviation without requiring a known cause, since a
novel anomaly by definition has none. The detector SHALL operate on low data (a rolling window) and
SHALL NOT defer or suppress a deviation for lack of an explanation. Robustness SHALL be an estimator
property (per-series scale, dispersion floors), not a learned large-n baseline.

#### Scenario: A spike is detected before any cause is known

- **GIVEN** a series with only a short rolling window of recent samples
- **WHEN** the current value deviates sharply from that window
- **THEN** the detector SHALL emit a deviation (magnitude + direction) regardless of whether the cause is known
- **AND** detection SHALL NOT wait on a seasonal/causal baseline being mature

### Requirement: Disposition Consumes Cause Context, Not Only Thresholds

The disposition kernel SHALL be able to consume **cause signals** from its `Context`, not only config
thresholds. Where the cause of a recurring-but-normal spike is observable in the fabric (process
attribution for host metrics, top-talker/port for traffic, link capacity for interfaces, reset/scan
flags for artifacts), the disposition SHALL be derivable as "is this deviation *expected given its
observable cause*?" rather than solely a distance-from-baseline test.

#### Scenario: A host CPU spike with a known process cause is dispositioned as expected

- **GIVEN** a detected CPU deviation on a host AND `sysmon.process` shows a known periodic consumer (e.g. a CI build) during the window
- **WHEN** the disposition kernel evaluates it with cause context available
- **THEN** it SHALL be able to disposition the spike as expected-recurring rather than escalate
- **AND** the same deviation with NO matching cause SHALL remain eligible to escalate

### Requirement: Conditional Baseline Conditions On Local Time

The conditional-baseline (seasonal) disposition SHALL evaluate "normal for this series at this time"
against the device's **local** hour-of-day / day-of-week, not UTC, so diurnal phasing is correct for
geographically distributed fleets.

#### Scenario: Diurnal baseline phases on local business hours

- **GIVEN** two devices in different timezones with the same local diurnal pattern
- **WHEN** the seasonal baseline scores a business-hours value on each
- **THEN** both SHALL be judged against their own local hour-of-day profile
- **AND** a value normal at 09:00 local SHALL NOT be mis-scored because the timestamp is UTC

### Requirement: No Overclaimed Methodology Naming

A component SHALL NOT be labeled "uncertainty-aware" (or presented as an established methodology)
unless it produces a calibrated uncertainty quantity — a posterior or an interval with coverage. The
robust deviation/peak-profile mechanics SHALL be named as such. UASB-branded kernel/stat/ABI
artifacts SHALL NOT remain in the tree; an honestly named robust peak profile may remain as
matched-resolution context for disposition.

#### Scenario: The robust band is named honestly

- **GIVEN** the robust per-series deviation estimator
- **WHEN** it is documented or surfaced
- **THEN** it SHALL be described as a robust detector, not as "uncertainty-aware" or a named methodology
- **AND** no inert "UASB" kernel/stat/ABI SHALL remain in the tree
