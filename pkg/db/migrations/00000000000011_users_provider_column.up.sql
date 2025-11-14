ALTER STREAM users
    ADD COLUMN IF NOT EXISTS provider string DEFAULT 'local';
