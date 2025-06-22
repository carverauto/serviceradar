-- Creates a stream to store CloudEvents from syslog, with a flattened data structure.
CREATE STREAM IF NOT EXISTS events (
    -- CloudEvents Context Attributes
    specversion string,
    id string,
    source string,
    type string,
    datacontenttype string,
    subject string,               -- Optional: As seen in your logs `Subject: events.syslog.processed`

    -- Flattened 'data' payload attributes
    remote_addr string,
    host string,
    level int32,                  -- Using int32 for the numeric level
    severity string,
    short_message string,
    event_timestamp datetime64(3),  -- Storing the event's own timestamp as a datetime
    version string,

    -- Raw data for auditing and reprocessing
    raw_data string
);