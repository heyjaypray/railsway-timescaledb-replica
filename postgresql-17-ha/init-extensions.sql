-- Standard Extensions (safe to run during initdb)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- Main Feature Extensions
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "vector"; -- pgvector
CREATE EXTENSION IF NOT EXISTS "pg_partman";

-- NOTE: pg_cron is created in entrypoint.sh background task
-- because it requires shared_preload_libraries which isn't loaded
-- until the REAL server starts (not the temporary initdb server)
