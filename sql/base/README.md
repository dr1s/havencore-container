# Base SQL Files

This directory holds the **base SQL dumps** used by the `db-init` service to create and populate the HavenCore databases on first run.

## Required Files

Place the following files in this directory before starting the stack:

- `bfa_auth.sql` — Authentication and realmlist data
- `bfa_characters.sql` — Character data
- `bfa_hotfixes.sql` — Client hotfix data
- `bfa_world.sql` — World content data

## Where to Get Them

These dumps are **not included in this repository** (they are ignored by `.gitignore`). Download them from the upstream HavenCore release page:

<https://github.com/HavenWoW/BFA-HavenCore/releases/latest>

## How They Are Used

When the `db-init` container starts for the first time, it:

1. Creates the databases `bfa_auth`, `bfa_characters`, `bfa_hotfixes`, and `bfa_world`.
2. Imports the matching base SQL files from this directory.
3. Applies any incremental updates found in `sql/updates/` (bundled inside the `db-init` image).

After the initial import, `db-init` writes a marker file so it will skip the base import on subsequent runs but still apply new updates.

## File Mapping

| File                    | Database         |
| ----------------------- | ---------------- |
| `bfa_auth.sql`          | `bfa_auth`       |
| `bfa_characters.sql`    | `bfa_characters` |
| `bfa_hotfixes.sql`      | `bfa_hotfixes`   |
| `bfa_world.sql`         | `bfa_world`      |
