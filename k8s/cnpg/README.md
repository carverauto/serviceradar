# cloud-native postgres

## Auth Setup

After you create the auth, you might need to login with psql
manually through a port-forward and set the password for the `kratos` user.

```sql
-- Create users if they don't exist
CREATE USER hydra WITH PASSWORD 'your_password' SUPERUSER CREATEDB;
CREATE USER kratos WITH PASSWORD 'your_password' SUPERUSER CREATEDB;

-- Create databases
CREATE DATABASE hydra WITH OWNER hydra;
CREATE DATABASE kratos WITH OWNER kratos;

-- Connect to hydra database and set up permissions
\c hydra
GRANT ALL PRIVILEGES ON DATABASE hydra TO hydra;
GRANT ALL PRIVILEGES ON SCHEMA public TO hydra;
ALTER DATABASE hydra OWNER TO hydra;

-- Connect to kratos database and set up permissions
\c kratos
GRANT ALL PRIVILEGES ON DATABASE kratos TO kratos;
GRANT ALL PRIVILEGES ON SCHEMA public TO kratos;
ALTER DATABASE kratos OWNER TO kratos;

-- Ensure public schema exists and has correct permissions in both DBs
\c hydra
CREATE SCHEMA IF NOT EXISTS public;
GRANT ALL ON SCHEMA public TO hydra;
GRANT ALL ON ALL TABLES IN SCHEMA public TO hydra;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO hydra;

\c kratos
CREATE SCHEMA IF NOT EXISTS public;
GRANT ALL ON SCHEMA public TO kratos;
GRANT ALL ON ALL TABLES IN SCHEMA public TO kratos;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO kratos;
```
