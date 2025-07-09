-- Update events stream to support CloudEvents format
-- This migration updates the events stream to match the db-event-writer processor expectations

-- Drop the existing events stream
DROP STREAM IF EXISTS events;

-- Recreate events stream with CloudEvents schema
CREATE STREAM IF NOT EXISTS events (
    -- CloudEvents standard fields
    specversion       string,
    id                string,
    source            string,
    type              string,
    datacontenttype   string,
    subject           string,
    
    -- Event data fields
    remote_addr       string,
    host              string,
    level             int32,
    severity          string,
    short_message     string,
    event_timestamp   DateTime64(3),
    version           string,
    
    -- Raw data for debugging
    raw_data          string
) PRIMARY KEY (id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';