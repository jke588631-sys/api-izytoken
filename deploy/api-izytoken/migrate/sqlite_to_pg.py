#!/usr/bin/env python3
"""sqlite_to_pg.py — new-api SQLite -> PostgreSQL migration.

Modes:
  full  <sqlite_file> <out_t0max>   : background full load (TRUNCATE PG first; logs 30-day filter)
  delta <sqlite_file> <t0max_file>  : cutover final sync (config tables TRUNCATE+reload; logs id>T0_max)
  check <sqlite_file>               : compare row counts sqlite vs PG

Env: PG_HOST/PG_PORT/PG_DB/PG_USER/PG_PASS (default 127.0.0.1:5433 new-api root)
"""
import sys, os, io, time, json, datetime, sqlite3
import psycopg2
from psycopg2 import extras

PG_HOST = os.environ.get("PG_HOST", "127.0.0.1")
PG_PORT = int(os.environ.get("PG_PORT", "5433"))
PG_DB = os.environ.get("PG_DB", "new-api")
PG_USER = os.environ.get("PG_USER", "root")
PG_PASS = os.environ.get("PG_PASS", "")
CUTOFF_DAYS = 30
LOGS_TABLE = "logs"
BATCH = 2000


def pg_conn():
    return psycopg2.connect(host=PG_HOST, port=PG_PORT, dbname=PG_DB, user=PG_USER, password=PG_PASS)


def sqlite_conn(path, ro=True):
    uri = "file:%s?mode=ro" % path if ro else "file:%s" % path
    conn = sqlite3.connect(uri, uri=True)
    conn.text_factory = lambda b: b.decode("utf-8", "replace")
    return conn


def pg_tables(pgc):
    with pgc.cursor() as cur:
        cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")
        return [r[0] for r in cur.fetchall()]


def pg_cols(pgc, table):
    with pgc.cursor() as cur:
        cur.execute("""SELECT column_name, data_type FROM information_schema.columns
                       WHERE table_schema='public' AND table_name=%s ORDER BY ordinal_position""", (table,))
        return {r[0]: r[1] for r in cur.fetchall()}


def sqlite_cols(sc, table):
    cur = sc.cursor()
    cur.execute("PRAGMA table_info(%s)" % table)
    return {r[1]: r[2] for r in cur.fetchall()}


def convert(value, pg_type):
    if value is None:
        return None
    t = pg_type
    if t == "bytea":
        return value if isinstance(value, bytes) else str(value).encode("utf-8")
    # SQLite may store text/json columns as BLOB (bytes); decode before further handling
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    if t == "boolean":
        return bool(value)
    if t in ("bigint", "integer", "smallint"):
        return int(value)
    if t in ("numeric", "decimal", "double precision", "real"):
        return float(value)
    if t in ("json", "jsonb"):
        if isinstance(value, str):
            s = value.strip()
            if s == "":
                return None
            try:
                return extras.Json(json.loads(s))
            except Exception:
                return extras.Json(s)
        return extras.Json(value)
    if t in ("timestamp with time zone", "timestamp without time zone"):
        if isinstance(value, (int, float)):
            v = int(value)
            return None if v <= 0 else datetime.datetime.fromtimestamp(v, tz=datetime.timezone.utc)
        return value
    return str(value)


def load_table(pgc, sc, table, where=None, params=(), truncate=False):
    pgcols = pg_cols(pgc, table)
    if not pgcols:
        print("  skip (no pg cols):", table)
        return 0
    scol = sqlite_cols(sc, table)
    cols = [c for c in scol if c in pgcols]
    if not cols:
        print("  skip (no common cols):", table)
        return 0
    sel = 'SELECT %s FROM "%s"' % (", ".join('"%s"' % c for c in cols), table)
    if where:
        sel += " WHERE " + where
    s_cur = sc.cursor()
    s_cur.execute(sel, params)
    ins = 'INSERT INTO public."%s" (%s) VALUES %%s' % (table, ", ".join('"%s"' % c for c in cols))
    total = 0
    with pgc.cursor() as pc:
        if truncate:
            pc.execute('TRUNCATE TABLE public."%s"' % table)
        while True:
            rows = s_cur.fetchmany(BATCH)
            if not rows:
                break
            conv = [[convert(v, pgcols[c]) for c, v in zip(cols, row)] for row in rows]
            extras.execute_values(pc, ins, conv, page_size=BATCH)
            total += len(rows)
    return total


def fix_sequences(pgc, tables):
    for t in tables:
        # commit any prior aborted transaction before each setval attempt
        try:
            pgc.commit()
        except Exception:
            pass
        try:
            with pgc.cursor() as cur:
                cur.execute("SELECT pg_get_serial_sequence('public.%s', 'id')" % t)
                seq = cur.fetchone()[0]
                if seq:
                    cur.execute("SELECT COALESCE(MAX(id),0) FROM public.%s" % t)
                    mx = cur.fetchone()[0]
                    cur.execute("SELECT setval(%s, %s)", (seq, mx))
                    print("  setval %s -> %s" % (t, mx))
                else:
                    print("  seq skip %s (no serial id col)" % t)
            pgc.commit()
        except Exception as e:
            print("  seq skip %s: %s" % (t, e))
            try:
                pgc.rollback()
            except Exception:
                pass


def cutoff_ts():
    return int(time.time()) - CUTOFF_DAYS * 86400


def mode_full(src, out_t0max):
    sc = sqlite_conn(src)
    pgc = pg_conn()
    tables = pg_tables(pgc)
    for t in tables:
        try:
            with pgc.cursor() as cur:
                cur.execute('TRUNCATE TABLE public."%s" CASCADE' % t)
        except Exception as e:
            print("truncate err", t, e)
    pgc.commit()
    cut = cutoff_ts()
    for t in tables:
        if t == LOGS_TABLE:
            n = load_table(pgc, sc, t, where="created_at >= %d" % cut)
        else:
            n = load_table(pgc, sc, t)
        print("%-28s %10d" % (t, n))
        pgc.commit()
    # T0_max = max id ACTUALLY loaded into PG (not a fresh query on live source)
    with pgc.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(id),0) FROM logs")
        t0max = cur.fetchone()[0]
    with open(out_t0max, "w") as f:
        f.write(str(t0max))
    print("T0_max =", t0max, "->", out_t0max)
    fix_sequences(pgc, tables)
    with pgc.cursor() as cur:
        cur.execute("ANALYZE")
    pgc.commit()
    print("full mode done")


def mode_delta(src, t0max_file):
    with open(t0max_file) as f:
        t0max = int(f.read().strip())
    sc = sqlite_conn(src)
    pgc = pg_conn()
    tables = pg_tables(pgc)
    with pgc.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(id),0) FROM logs")
        pgmax = cur.fetchone()[0]
    print("PG logs max(id) =", pgmax, "T0_max(file) =", t0max)
    # resume boundary = max(t0max, pgmax): idempotent across repeated delta runs
    # (if a prior run failed after loading some rows, pgmax is already ahead)
    delta_from = max(t0max, pgmax)
    if pgmax > t0max:
        print("NOTE: PG ahead of t0max (%d > %d); resuming from %d" % (pgmax, t0max, delta_from))
    cut = cutoff_ts()
    for t in tables:
        if t == LOGS_TABLE:
            n = load_table(pgc, sc, t, where="id > %d AND created_at >= %d" % (delta_from, cut))
            print("logs delta rows:", n)
        else:
            n = load_table(pgc, sc, t, truncate=True)
            print("%-28s reloaded %10d" % (t, n))
        pgc.commit()
    fix_sequences(pgc, tables)
    with pgc.cursor() as cur:
        cur.execute("ANALYZE")
    pgc.commit()
    # advance t0_max file to the new PG max so next delta starts after it
    with pgc.cursor() as cur:
        cur.execute("SELECT COALESCE(MAX(id),0) FROM logs")
        newmax = cur.fetchone()[0]
    with open(t0max_file, "w") as f:
        f.write(str(newmax))
    print("delta mode done. new T0_max =", newmax)


def mode_check(src):
    sc = sqlite_conn(src)
    pgc = pg_conn()
    tables = pg_tables(pgc)
    cut = cutoff_ts()
    for t in tables:
        s_cur = sc.cursor()
        if t == LOGS_TABLE:
            s_cur.execute("SELECT count(*) FROM \"%s\" WHERE created_at >= %d" % (t, cut))
        else:
            s_cur.execute("SELECT count(*) FROM \"%s\"" % t)
        scnt = s_cur.fetchone()[0]
        with pgc.cursor() as cur:
            cur.execute("SELECT count(*) FROM public.\"%s\"" % t)
            pcnt = cur.fetchone()[0]
        mark = "OK" if scnt == pcnt else "MISMATCH"
        print("%-28s sqlite=%10d pg=%10d  %s" % (t, scnt, pcnt, mark))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "full":
        mode_full(sys.argv[2], sys.argv[3])
    elif mode == "delta":
        mode_delta(sys.argv[2], sys.argv[3])
    elif mode == "check":
        mode_check(sys.argv[2])
    else:
        print("unknown mode", mode)
        sys.exit(1)
