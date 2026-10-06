import io
import psycopg2

TABLES = ["egg_production", "mortality", "feed_consumption", "feed_received",
          "egg_dispatch", "medications", "dispatch_requests"]
COLS = ["farm_id", "flock_id", "section_no", "sync_status"]

c = psycopg2.connect(host="127.0.0.1", port=5433, user="postgres",
                     dbname="madjana_test", password="", sslmode="disable")
cur = c.cursor()
out = []
for t in TABLES:
    cur.execute(
        "SELECT column_name, is_nullable, column_default "
        "FROM information_schema.columns "
        "WHERE table_schema='public' AND table_name=%s AND column_name = ANY(%s) "
        "ORDER BY column_name", (t, COLS))
    out.append(f"{t}:")
    for name, nullable, default in cur.fetchall():
        d = (default or "")[:40]
        out.append(f"   {name:14s} nullable={nullable:3s} default={d}")
c.close()
io.open(r"C:\Users\MTC\Desktop\madjana\sp.txt", "w",
        encoding="utf-8").write("\n".join(out))