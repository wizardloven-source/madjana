import io
import psycopg2

c = psycopg2.connect(host="127.0.0.1", port=5433, user="postgres",
                     dbname="madjana_test", password="", sslmode="disable")
cur = c.cursor()
cur.execute("SELECT table_name, sort_order FROM public.sync_table_registry "
            "ORDER BY sort_order, table_name")
rows = cur.fetchall()
out = [f"rows={len(rows)}"]
out += [f"  {r[0]:30s} {r[1]}" for r in rows]
cur.execute("SELECT count(*) FROM public.sync_table_registry "
            "WHERE table_name = 'egg_production'")
out.append(f"egg_production rows in registry: {cur.fetchone()[0]}")
c.close()
io.open(r"C:\Users\MTC\Desktop\madjana\sp.txt", "w",
        encoding="utf-8").write("\n".join(out))