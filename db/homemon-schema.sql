-- Node information
CREATE TABLE IF NOT EXISTS nodes (
                                     node_id TEXT PRIMARY KEY,
                                     first_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                     last_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                     is_healthy BOOLEAN NOT NULL DEFAULT 0
);

-- Node status history
CREATE TABLE IF NOT EXISTS node_history (
                                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                                            node_id TEXT NOT NULL,
                                            timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                            is_healthy BOOLEAN NOT NULL DEFAULT 0,
                                            FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
    );

-- Service status
CREATE TABLE IF NOT EXISTS service_status (
                                              id INTEGER PRIMARY KEY AUTOINCREMENT,
                                              node_id TEXT NOT NULL,
                                              service_name TEXT NOT NULL,
                                              service_type TEXT NOT NULL,
                                              available BOOLEAN NOT NULL DEFAULT 0,
                                              details TEXT,
                                              timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                              FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
    );

-- Service history
CREATE TABLE IF NOT EXISTS service_history (
                                               id INTEGER PRIMARY KEY AUTOINCREMENT,
                                               service_status_id INTEGER NOT NULL,
                                               timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                                               available BOOLEAN NOT NULL DEFAULT 0,
                                               details TEXT,
                                               FOREIGN KEY (service_status_id) REFERENCES service_status(id) ON DELETE CASCADE
    );

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_node_history_node_time
    ON node_history(node_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_service_status_node_time
    ON service_status(node_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_service_status_type
    ON service_status(service_type);
CREATE INDEX IF NOT EXISTS idx_service_history_status_time
    ON service_history(service_status_id, timestamp);

-- Enable WAL mode for better concurrent access
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;