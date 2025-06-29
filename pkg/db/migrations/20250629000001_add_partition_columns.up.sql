-- Add partition column to service_status stream
ALTER STREAM service_status ADD COLUMN partition string;

-- Add partition column to services stream  
ALTER STREAM services ADD COLUMN partition string;

-- Add partition column to sysmon metrics streams
ALTER STREAM cpu_metrics ADD COLUMN partition string;
ALTER STREAM disk_metrics ADD COLUMN partition string;
ALTER STREAM memory_metrics ADD COLUMN partition string;