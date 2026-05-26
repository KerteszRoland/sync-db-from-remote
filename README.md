# Sync Local Postgres DB from Remote

Local development database synced from the remote PostgreSQL instance.

## Prerequisites

- Docker

## Setup

1. Create your `.env` file from the template:

   ```bash
   cp .env.example .env
   ```

2. Fill in `.env` with your values. All configuration is in one file:

   ```
   # Remote database connection
   REMOTE_DB_HOST=your-host.com
   REMOTE_DB_PORT=5432
   REMOTE_DB_NAME=your_db
   REMOTE_DB_USER=your_user
   REMOTE_DB_PASSWORD=your_password

   # Optional: keep previous dumps in backup/ (timestamped seed.dump.*)
   BACKUP_PREVIOUS_DUMP=false

   # Local Docker database
   POSTGRES_USER=dbuser
   POSTGRES_PASSWORD=localdb
   POSTGRES_DB=mydb

   # Variables for post-init.sql substitution (see Post-init SQL)
   DEV_API_URL=your-api-url
   ```

## Usage

Sync the remote database and start the local container:

```bash
./sync-db.sh -r
```

Or sync and start separately:

```bash
./sync-db.sh
docker compose down -v && docker compose up -d
```

The local database is available at:

| Field    | Value                                |
| -------- | ------------------------------------ |
| Host     | `localhost`                          |
| Port     | `5432`                               |
| Database | Value of `POSTGRES_DB` in .env       |
| User     | Value of `POSTGRES_USER` in .env     |
| Password | Value of `POSTGRES_PASSWORD` in .env |

## Post-init SQL

`post-init.sql` runs after the schema and data are imported. Use it to replace values for local development (e.g. API keys, URLs).

Variables use `${VAR_NAME}` syntax and are substituted from `.env` at container startup:

```sql
UPDATE settings
SET api_url = '${DEV_API_URL}'
WHERE key = 'api_url';
```

Then in `.env`:

```
DEV_API_URL=your-api-url
```

## Re-syncing

To pull a fresh copy of the remote database, run `./sync-db.sh -r` again. The `-r` flag tears down the existing container (including its data volume) and starts a fresh one.

Set `BACKUP_PREVIOUS_DUMP=true` in `.env` to move the existing `sql/seed.dump` into `backup/` (as `seed.dump.YYYYMMDD-HHMMSS`) before each sync instead of overwriting it. Override the folder with `DUMP_BACKUP_DIR` if needed.

## Files

| File                 | Purpose                                                    |
| -------------------- | ---------------------------------------------------------- |
| `sync-db.sh`         | Dumps remote DB to local SQL files                         |
| `docker-compose.yml` | Local PostgreSQL container                                 |
| `post-init.sql`      | SQL that runs after import, supports `${VAR}` substitution |
| `.env`               | Connection credentials and substitution variables          |
| `sql/`               | Generated dump and init scripts (gitignored)               |
| `backup/`            | Archived previous dumps when `BACKUP_PREVIOUS_DUMP=true`   |

## License

This project is licensed under the MIT License.
