-- complain if script is sourced in psql, rather than via create extension
\echo Use "CREATE EXTENSION quick_sync" to load this file. \quit

-- =============================================================================
--   ____  ___  _   _ _   _ _____ ____ _____ ___ ___  _   _ ____  
--  / ___|/ _ \| \ | | \ | | ____/ ___|_   _|_ _/ _ \| \ | / ___| 
-- | |   | | | |  \| |  \| |  _|| |     | |  | | | | |  \| \___ \ 
-- | |___| |_| | |\  | |\  | |__| |___  | |  | | |_| | |\  |___) |
--  \____|\___/|_| \_|_| \_|_____\____| |_| |___\___/|_| \_|____/ 
--
--  module: connection management
--  functions: list_connections, create_connection, edit_connection, delete_connection
-- =============================================================================

-- =============================================================================
--  ┌─┐┌─┐┌┬┐┬ ┬┌─┐
--  └─┐├┤  │ │ │├─┘   module: extension schema & internal tables
--  └─┘└─┘ ┴ └─┘┴  
-- =============================================================================

create schema if not exists quick_sync;

create table if not exists quick_sync.connections (
    alias        text primary key,
    server_name  text unique not null,
    host         text not null,
    port         int  not null default 5432,
    dbname       text not null,
    remote_user  text not null,
    fetch_size   int  not null default 50000,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
--  ┬  ┬┌─┐┌┬┐  ┌─┐┌─┐┌┐┌┌┐┌┌─┐┌─┐┌┬┐┬┌─┐┌┐┌┌─┐
--  │  │└─┐ │   │  │ │││││││├┤ │   │ ││ ││││└─┐
--  ┴─┘┴└─┘ ┴   └─┘└─┘┘└┘┘└┘└─┘└─┘ ┴ ┴└─┘┘└┘└─┘
--  returns all registered connections and validates catalog status
-- -----------------------------------------------------------------------------

create or replace function quick_sync.list_connections()
returns table (
    alias           text,
    server_name     text,
    host            text,
    port            int,
    dbname          text,
    remote_user     text,
    fetch_size      int,
    foreign_tables  bigint,
    is_active       boolean,
    updated_at      timestamptz
)
language sql
stable
as $$
    select 
        c.alias,
        c.server_name,
        c.host,
        c.port,
        c.dbname,
        c.remote_user,
        c.fetch_size,
        (
            select count(*)
            from pg_foreign_table ft
            join pg_foreign_server srv on srv.oid = ft.ftserver
            where srv.srvname = c.server_name
        ) as foreign_tables,
        exists (
            select 1 
            from pg_foreign_server srv 
            where srv.srvname = c.server_name
        ) as is_active,
        c.updated_at
    from quick_sync.connections c
    order by c.alias;
$$;

-- -----------------------------------------------------------------------------
--  ┌─┐┬─┐┌─┐┌─┐┌┬┐┌─┐  ┌─┐┌─┐┌┐┌┌┐┌┌─┐┌─┐┌┬┐┬┌─┐┌┐┌
--  │  ├┬┘├┤ ├─┤ │ ├┤   │  │ │││││││├┤ │   │ ││ ││││
--  └─┘┴└─└─┘┴ ┴ ┴ └─┘  └─┘└─┘┘└┘┘└┘└─┘└─┘ ┴ ┴└─┘┘└┘
--  parses uri, creates foreign server and user mapping, and logs metadata
-- -----------------------------------------------------------------------------

create or replace function quick_sync.create_connection(
    p_alias       text,
    p_uri         text,
    p_fetch_size  int default 50000
)
returns text
language plpgsql
as $$
declare
    v_alias        text;
    v_matches      text[];
    v_user         text;
    v_password     text;
    v_host         text;
    v_port         int;
    v_dbname       text;
    v_server_name  text;
begin
    v_alias := lower(trim(p_alias));

    -- validate alias identifier format and uniqueness
    if v_alias is null or v_alias !~ '^[a-z_][a-z0-9_]*$' then
        raise exception 'invalid alias "%". use only lowercase letters, numbers, and underscores.', p_alias;
    end if;

    if exists (select 1 from quick_sync.connections where alias = v_alias) then
        raise exception 'connection "%" already exists. use quick_sync.edit_connection() or delete it first.', v_alias;
    end if;

    -- parse connection uri: postgres://user:pass@host:port/dbname
    v_matches := regexp_match(
        p_uri,
        '^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::(\d+))?/([^?]+)'
    );

    if v_matches is null then
        raise exception 'invalid uri format. expected: postgres://user:password@host:port/dbname';
    end if;

    v_user        := v_matches[1];
    v_password    := v_matches[2];
    v_host        := v_matches[3];
    v_port        := coalesce(v_matches[4]::int, 5432);
    v_dbname      := v_matches[5];
    v_server_name := 'qsync_srv_' || v_alias;

    -- create optimized foreign server
    execute format(
        'create server %I foreign data wrapper postgres_fdw options (host %L, port %L, dbname %L, fetch_size %L, use_remote_estimate %L)',
        v_server_name,
        v_host,
        v_port::text,
        v_dbname,
        p_fetch_size::text,
        'true'
    );

    -- create user mapping for current user
    execute format(
        'create user mapping for current_user server %I options (user %L, password %L)',
        v_server_name,
        v_user,
        v_password
    );

    -- persist connection metadata (excluding password)
    insert into quick_sync.connections (
        alias, server_name, host, port, dbname, remote_user, fetch_size
    ) values (
        v_alias, v_server_name, v_host, v_port, v_dbname, v_user, p_fetch_size
    );

    return format('connection "%s" created successfully (server: %s).', v_alias, v_server_name);
end;
$$;

-- -----------------------------------------------------------------------------
--  ┌─┐┌┬┐┬┌┬┐  ┌─┐┌─┐┌┐┌┌┐┌┌─┐┌─┐┌┬┐┬┌─┐┌┐┌
--  ├┤  │││ │   │  │ │││││││├┤ │   │ ││ ││││
--  └─┘─┴┘┴ ┴   └─┘└─┘┘└┘┘└┘└─┘└─┘ ┴ ┴└─┘┘└┘
--  updates host, port, credentials, or fetch_size via uri or named params
-- -----------------------------------------------------------------------------

create or replace function quick_sync.edit_connection(
    p_alias       text,
    p_uri         text default null,
    p_host        text default null,
    p_port        int  default null,
    p_dbname      text default null,
    p_user        text default null,
    p_password    text default null,
    p_fetch_size  int  default null
)
returns text
language plpgsql
as $$
declare
    v_alias       text;
    v_conn        quick_sync.connections%rowtype;
    v_matches     text[];
    v_host        text;
    v_port        int;
    v_dbname      text;
    v_user        text;
    v_password    text;
    v_fetch_size  int;
begin
    v_alias := lower(trim(p_alias));

    select * into v_conn
    from quick_sync.connections
    where alias = v_alias;

    if not found then
        raise exception 'connection "%" does not exist.', v_alias;
    end if;

    -- extract base values if uri is provided
    if p_uri is not null then
        v_matches := regexp_match(
            p_uri,
            '^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::(\d+))?/([^?]+)'
        );

        if v_matches is null then
            raise exception 'invalid uri format. expected: postgres://user:password@host:port/dbname';
        end if;

        v_user     := coalesce(p_user, v_matches[1]);
        v_password := coalesce(p_password, v_matches[2]);
        v_host     := coalesce(p_host, v_matches[3]);
        v_port     := coalesce(p_port, v_matches[4]::int, 5432);
        v_dbname   := coalesce(p_dbname, v_matches[5]);
    else
        v_host     := coalesce(p_host, v_conn.host);
        v_port     := coalesce(p_port, v_conn.port);
        v_dbname   := coalesce(p_dbname, v_conn.dbname);
        v_user     := coalesce(p_user, v_conn.remote_user);
        v_password := p_password; -- updated only if provided
    end if;

    v_fetch_size := coalesce(p_fetch_size, v_conn.fetch_size);

    -- update foreign server options
    execute format(
        'alter server %I options (set host %L, set port %L, set dbname %L, set fetch_size %L)',
        v_conn.server_name,
        v_host,
        v_port::text,
        v_dbname,
        v_fetch_size::text
    );

    -- update user mapping credentials
    if v_password is not null then
        execute format(
            'alter user mapping for current_user server %I options (set user %L, set password %L)',
            v_conn.server_name,
            v_user,
            v_password
        );
    elsif p_user is not null then
        execute format(
            'alter user mapping for current_user server %I options (set user %L)',
            v_conn.server_name,
            v_user
        );
    end if;

    -- update catalog metadata
    update quick_sync.connections
    set host        = v_host,
        port        = v_port,
        dbname      = v_dbname,
        remote_user = v_user,
        fetch_size  = v_fetch_size,
        updated_at  = now()
    where alias = v_alias;

    return format('connection "%s" updated successfully.', v_alias);
end;
$$;

-- -----------------------------------------------------------------------------
--  ┌┬┐┌─┐┬  ┌─┐┌┬┐┌─┐  ┌─┐┌─┐┌┐┌┌┐┌┌─┐┌─┐┌┬┐┬┌─┐┌┐┌
--   ││├┤ │  ├┤  │ ├┤   │  │ │││││││├┤ │   │ ││ ││││
--  ─┴┘└─┘┴─┘└─┘ ┴ └─┘  └─┘└─┘┘└┘┘└┘└─┘└─┘ ┴ ┴└─┘┘└┘
--  drops user mapping, foreign server, and metadata record
-- -----------------------------------------------------------------------------

create or replace function quick_sync.delete_connection(
    p_alias    text,
    p_cascade  boolean default true
)
returns text
language plpgsql
as $$
declare
    v_alias  text;
    v_conn   quick_sync.connections%rowtype;
begin
    v_alias := lower(trim(p_alias));

    select * into v_conn
    from quick_sync.connections
    where alias = v_alias;

    if not found then
        raise exception 'connection "%" does not exist.', v_alias;
    end if;

    -- drop user mapping explicitly
    execute format(
        'drop user mapping if exists for current_user server %I',
        v_conn.server_name
    );

    -- drop foreign server
    if p_cascade then
        execute format('drop server if exists %I cascade', v_conn.server_name);
    else
        execute format('drop server if exists %I restrict', v_conn.server_name);
    end if;

    -- delete metadata record
    delete from quick_sync.connections where alias = v_alias;

    return format('connection "%s" deleted successfully.', v_alias);
end;
$$;