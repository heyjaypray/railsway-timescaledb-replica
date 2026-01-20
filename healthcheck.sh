#!/bin/bash
set -e

# Try to connect to postgres
pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}"
