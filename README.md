# pg-quick-sync

Ergonomic PostgreSQL extension for managing `postgres_fdw` connections via URIs and incremental data synchronization.

> **Status:** `v0.1.0` — Connection management CRUD module complete. Table mapping and incremental sync modules are in active development.

## Features

- **URI-based connection setup:** Configure foreign servers and user mappings with a single PostgreSQL connection string (`postgres://user:pass@host:port/dbname`).
- **Safe credential inventory:** Tracks connection metadata in `quick_sync.connections` without storing plaintext passwords in custom tables.
- **Full CRUD lifecycle:** List, create, edit (granular parameters or full URI), and safely drop foreign connections.
- **Tuned defaults:** Automatically configures `fetch_size` (default `50000`) and `use_remote_estimate` on created foreign servers.

## Installation

### Requirements
- PostgreSQL 13+
- `postgres_fdw` contrib module installed

### Build & Install
```bash
git clone [https://github.com/angelmorgaldev/pg-quick-sync.git](https://github.com/angelmorgaldev/pg-quick-sync.git)
cd pg-quick-sync
make install