# HavenCore Container

A containerized deployment for [HavenCore](https://github.com/HavenWoW/BFA-HavenCore), a Battle for Azeroth (BFA) World of Warcraft private-server emulator.

This repository provides ready-to-use container images, compose definitions, and database initialization tooling so you can run `bnetserver` and `worldserver` with MySQL without compiling the server locally.

## Overview

The compose stack consists of the following services:

| Service       | Purpose                                                       |
| ------------- | ------------------------------------------------------------- |
| `db`          | MySQL 8.4 database server                                     |
| `db-init`     | Creates databases, imports base SQL, and applies updates      |
| `worldserver` | Game world server (ports `8085`/`8086`)                       |
| `bnetserver`  | Battle.net authentication server (ports `1119`/`8081`)        |
| `extractors`  | Optional profile to extract client data from a WoW client     |

## Prerequisites

- [Docker](https://docs.docker.com/) or [Podman](https://podman.io/) with compose support
- A copy of the HavenCore base SQL files:
  - `sql/base/bfa_auth.sql`
  - `sql/base/bfa_characters.sql`
  - `sql/base/bfa_hotfixes.sql`
  - `sql/base/bfa_world.sql`

> These SQL files are not included in the repository. Place them in `sql/base/` before starting the stack.

## Quick Start

1. Copy the example environment file and edit it to your needs:

   ```bash
   cp .env.example .env
   ```

2. Ensure the base SQL files are present in `sql/base/`.

3. Start the services:

   ```bash
   docker compose -f container-compose.yml up -d
   ```

   For Podman users, include the override file:

   ```bash
   podman-compose -f container-compose.yml -f container-compose.podman.override.yml up -d
   ```

4. The database initialization runs once and creates the `bfa_auth`, `bfa_world`, `bfa_characters`, and `bfa_hotfixes` databases. The `worldserver` and `bnetserver` services start once the database is healthy and initialized.

## Creating an Account

Once `worldserver` is running, you can create game accounts and grant GM privileges through the worldserver console FIFO.

Replace `<container_cmd>` with `docker` or `podman` and `<username>` / `<password>` with your desired values.

### Create an account

```bash
<container_cmd> compose exec -u havencore worldserver bash -c \
  'echo "bnetaccount create <email> <password>" > /opt/havencore/run/worldserver.in'
```

### Set GM level

Grant GM level `3` on all realms (`-1`) for an account:

```bash
<container_cmd> compose exec -u havencore worldserver bash -c \
  'echo "account set gmlevel <email> 3 -1" > /opt/havencore/run/worldserver.in'
```

## Extracting Client Data

> [!IMPORTANT]
> This process will take several hours to complete.

To generate maps, vmaps, mmaps, and other data files from a WoW client, use the optional `extractors` profile:

1. Edit `container-compose.yml` (or the override) to mount your client directory:

   ```yaml
   extractors:
     volumes:
       - /path/to/wow/client:/client:Z
   ```

2. Run the extractors:

   ```bash
   docker compose -f container-compose.yml --profile extractors run --rm extractors
   ```

Extracted data is written to the `client-data` volume (or the path configured by `CLIENT_DATA_VOL`) and mounted into `worldserver`.

## Configuration

The stack is configured through environment variables in `.env`:

| Variable                 | Description                                      | Default                                        |
| ------------------------ | ------------------------------------------------ | ---------------------------------------------- |
| `HAVENCORE_SERVER_IMAGE` | Image used for server services                   | `ghcr.io/dr1s/havencore-server:latest`         |
| `HAVENCORE_DBINIT_IMAGE` | Image used for database initialization           | `ghcr.io/dr1s/havencore-db-init:latest`        |
| `DB_HOST`                | Database hostname                                | `db`                                           |
| `DB_PORT`                | Database port                                    | `3306`                                         |
| `DB_USER`                | Application database user                        | `havencore`                                    |
| `DB_PASSWORD`            | Application database password                    | `havencore`                                    |
| `DB_ROOT_PASSWORD`       | MySQL root password                              | `havencore`                                    |
| `WORLD_IP`               | Realmlist address advertised to clients          | (optional)                                     |
| `WORLD_NAME`             | Realmlist name shown in the client               | (optional)                                     |
| `DB_DATA_VOL`            | Volume or path for MySQL data                    | `dbdata`                                       |
| `CLIENT_DATA_VOL`        | Volume or path for extracted client data         | `client-data`                                  |
| `LOGS_VOL`               | Volume or path for server logs                   | `logs`                                         |

### Realmlist

Set `WORLD_IP` to the public address clients should connect to. The `db-init` service updates the `realmlist` table in `bfa_auth` automatically on startup. `WORLD_NAME` can be used to customize the realm name.

### Podman

`container-compose.podman.override.yml` adds SELinux labels (`:z` / `:Z`) and `userns_mode: keep-id` for rootless Podman deployments.

## Persistent Data

The following paths/volumes are used for persistence:

- `dbdata` (or `DB_DATA_VOL`) — MySQL data files
- `client-data` (or `CLIENT_DATA_VOL`) — Extracted client data
- `logs` (or `LOGS_VOL`) — Server log files
- `./etc` — Server configuration files (`worldserver.conf`, `bnetserver.conf`)

## License

This project is a deployment wrapper. HavenCore and World of Warcraft assets belong to their respective owners.
