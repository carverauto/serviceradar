CREATE TABLE nodes (
    id TEXT PRIMARY KEY,
    first_seen TIMESTAMP,
    last_seen TIMESTAMP,
    is_healthy BOOLEAN
);

CREATE TABLE service_checks (
    id INTEGER PRIMARY KEY,
    node_id TEXT,
    service_name TEXT,
    service_type TEXT,
    available BOOLEAN,
    details TEXT,
    timestamp TIMESTAMP,
    FOREIGN KEY (node_id) REFERENCES nodes(id)
);

CREATE TABLE network_sweeps (
    id INTEGER PRIMARY KEY,
    network TEXT,
    timestamp TIMESTAMP,
    completed BOOLEAN
);

CREATE TABLE sweep_results (
    id INTEGER PRIMARY KEY,
    sweep_id INTEGER,
    ip_address TEXT,
    port INTEGER,
    response_time INTEGER,
    is_up BOOLEAN,
    timestamp TIMESTAMP,
    FOREIGN KEY (sweep_id) REFERENCES network_sweeps(id)
);