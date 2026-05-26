#!/bin/bash
set -e

# Disable MSYS path conversion (fixes paths on Git Bash for Windows)
export MSYS_NO_PATHCONV=1

# Parse flags
RESTART=false
while getopts "r" opt; do
    case $opt in
        r) RESTART=true ;;
        *) echo "Usage: $0 [-r]"; echo "  -r  Restart Docker container after sync"; exit 1 ;;
    esac
done

# Load environment variables from .env file
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env file not found"
    echo "Please copy .env.example to .env and fill in your remote database credentials"
    exit 1
fi

# Validate required variables
if [ -z "$REMOTE_DB_HOST" ] || [ -z "$REMOTE_DB_NAME" ] || [ -z "$REMOTE_DB_USER" ]; then
    echo "Error: Missing required environment variables"
    echo "Please ensure REMOTE_DB_HOST, REMOTE_DB_NAME, and REMOTE_DB_USER are set in .env"
    exit 1
fi

# Set defaults
REMOTE_DB_PORT=${REMOTE_DB_PORT:-5432}

# Create sql directory if it doesn't exist
mkdir -p ./sql

# Drop legacy plain-SQL workflow artefacts (would run before / beside restore if left in place)
rm -f ./sql/01-schema.sql ./sql/02-data.sql ./sql/03-post-init.sh

# Archive previous dump before overwriting (BACKUP_PREVIOUS_DUMP=true in .env)
if [ "$BACKUP_PREVIOUS_DUMP" = "true" ] || [ "$BACKUP_PREVIOUS_DUMP" = "1" ] || [ "$BACKUP_PREVIOUS_DUMP" = "yes" ]; then
    BACKUP_DIR=${DUMP_BACKUP_DIR:-./backup}
    mkdir -p "$BACKUP_DIR"
    if [ -f ./sql/seed.dump ]; then
        backup_name="seed.dump.$(date +%Y%m%d-%H%M%S)"
        echo "Archiving previous dump to $BACKUP_DIR/$backup_name..."
        mv ./sql/seed.dump "$BACKUP_DIR/$backup_name"
    fi
fi

echo "Connecting to remote database at $REMOTE_DB_HOST:$REMOTE_DB_PORT..."

# Single custom-format dump (compressed archive). Local seed uses pg_restore, not psql COPY.
echo "Dumping remote database to ./sql/seed.dump (custom format)..."
docker run --rm \
    -e PGPASSWORD="$REMOTE_DB_PASSWORD" \
    -v "$(pwd)/sql:/dump" \
    postgres:18-alpine \
    pg_dump -h "$REMOTE_DB_HOST" \
            -p "$REMOTE_DB_PORT" \
            -U "$REMOTE_DB_USER" \
            -d "$REMOTE_DB_NAME" \
            -Fc \
            --no-owner \
            --no-privileges \
            -f /dump/seed.dump

echo "Writing ./sql/01-restore.sh..."
cat > ./sql/01-restore.sh << 'RESTORE'
#!/bin/sh
set -e
DUMP=/docker-entrypoint-initdb.d/seed.dump

# pg_restore uses exit 1 for "completed with warnings" — treat as success
pg_restore_wrap () {
    pg_restore "$@" || {
        r=$?
        if [ "$r" -eq 1 ]; then
            echo "pg_restore: completed with warnings (exit 1)."
            return 0
        fi
        exit "$r"
    }
}

echo "Restoring schema from seed.dump..."
pg_restore_wrap \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --schema-only \
    --no-owner \
    --no-privileges \
    --verbose \
    "$DUMP"

echo "Restoring data from seed.dump (triggers disabled for cyclic FKs)..."
pg_restore_wrap \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --data-only \
    --disable-triggers \
    --no-owner \
    --no-privileges \
    --verbose \
    "$DUMP"

echo "Restore finished."
RESTORE
chmod +x ./sql/01-restore.sh

# Generate post-init wrapper script if post-init.sql exists
if [ -f ./post-init.sql ]; then
    echo "Copying post-init.sql template..."
    cp ./post-init.sql ./sql/post-init.sql.template

    echo "Generating post-init wrapper..."
    cat > ./sql/02-post-init.sh << 'WRAPPER'
#!/bin/sh
TEMPLATE=/docker-entrypoint-initdb.d/post-init.sql.template
if [ -f "$TEMPLATE" ]; then
    echo "Running post-init.sql with variable substitution..."
    SQL=$(cat "$TEMPLATE")
    # Replace ${VAR_NAME} patterns with environment variable values
    for var in $(env | cut -d= -f1); do
        val=$(eval echo "\$$var")
        SQL=$(echo "$SQL" | sed "s|\${${var}}|${val}|g")
    done
    echo "Executing SQL:"
    echo "$SQL"
    echo "----------------------------------------"
    if echo "$SQL" | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 2>&1; then
        echo "post-init.sql completed successfully."
    else
        echo "ERROR: post-init.sql failed! Check the SQL above for issues."
        exit 1
    fi
else
    echo "No post-init.sql template found, skipping."
fi
WRAPPER
    chmod +x ./sql/02-post-init.sh
else
    rm -f ./sql/02-post-init.sh ./sql/post-init.sql.template
fi

echo "Done! seed.dump and init scripts are in ./sql/"

if [ "$RESTART" = true ]; then
    echo "Restarting Docker container..."
    docker compose down -v && docker compose up -d
else
    echo ""
    echo "To import into local Docker PostgreSQL:"
    echo "  docker compose down -v && docker compose up -d"
fi
