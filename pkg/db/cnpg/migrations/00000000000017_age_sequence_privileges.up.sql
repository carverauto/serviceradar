-- Ensure the application role can advance AGE graph sequences.
-- Grants usage/select/update on all sequences in the serviceradar schema and
-- sets defaults for future sequences.
DO $$
DECLARE
    seq record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        RAISE NOTICE 'Role serviceradar not found; skipping sequence grants';
        RETURN;
    END IF;

    FOR seq IN
        SELECT schemaname, sequencename
        FROM pg_sequences
        WHERE schemaname = 'serviceradar'
    LOOP
        EXECUTE format(
            'GRANT USAGE, SELECT, UPDATE ON SEQUENCE %I.%I TO serviceradar',
            seq.schemaname, seq.sequencename
        );
    END LOOP;

    ALTER DEFAULT PRIVILEGES IN SCHEMA serviceradar
        GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO serviceradar;
END $$;
