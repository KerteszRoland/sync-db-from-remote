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

echo "Connecting to remote database at $REMOTE_DB_HOST:$REMOTE_DB_PORT..."

# Dump schema only (using Docker to run pg_dump)
echo "Dumping schema to ./sql/01-schema.sql..."
docker run --rm \
    -e PGPASSWORD="$REMOTE_DB_PASSWORD" \
    -v "$(pwd)/sql:/dump" \
    postgres:18-alpine \
    pg_dump -h "$REMOTE_DB_HOST" \
            -p "$REMOTE_DB_PORT" \
            -U "$REMOTE_DB_USER" \
            -d "$REMOTE_DB_NAME" \
            --schema-only \
            --no-owner \
            --no-privileges \
            -f /dump/01-schema.sql

# Dump data only
echo "Dumping data to ./sql/02-data.sql..."
docker run --rm \
    -e PGPASSWORD="$REMOTE_DB_PASSWORD" \
    -v "$(pwd)/sql:/dump" \
    postgres:18-alpine \
    pg_dump -h "$REMOTE_DB_HOST" \
            -p "$REMOTE_DB_PORT" \
            -U "$REMOTE_DB_USER" \
            -d "$REMOTE_DB_NAME" \
            --data-only \
            --no-owner \
            --no-privileges \
            -f /dump/02-data.sql

# Generate post-init wrapper script if post-init.sql exists
if [ -f ./post-init.sql ]; then
    echo "Copying post-init.sql template..."
    cp ./post-init.sql ./sql/post-init.sql.template

    echo "Generating post-init wrapper..."
    cat > ./sql/03-post-init.sh << 'WRAPPER'
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
    chmod +x ./sql/03-post-init.sh
fi

echo "Done! SQL files have been saved to ./sql/"

if [ "$RESTART" = true ]; then
    echo "Restarting Docker container..."
    docker compose down -v && docker compose up -d
else
    echo ""
    echo "To import into local Docker PostgreSQL:"
    echo "  docker compose down -v && docker compose up -d"
fi
