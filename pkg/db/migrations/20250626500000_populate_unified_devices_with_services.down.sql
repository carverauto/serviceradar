-- Rollback script for populating unified_devices with service devices
-- Remove all service devices from unified_devices

DELETE FROM unified_devices WHERE device_type = 'service_device';