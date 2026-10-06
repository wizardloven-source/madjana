import sys
import psycopg2

c = psycopg2.connect(host="127.0.0.1", port=5433, user="postgres",
                     dbname="madjana_test", password="", sslmode="disable")
cur = c.cursor()
cur.execute("SELECT conname, confdeltype FROM pg_constraint "
            "WHERE conrelid = 'public.flock_movements'::regclass "
            "AND contype = 'f' ORDER BY conname")
rows = cur.fetchall()
code = {"a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL",
        "d": "SET DEFAULT"}
if not rows:
    print("NO FOREIGN KEYS on flock_movements")
for name, d in rows:
    print(f"  {name:45s} ON DELETE {code.get(d, d)}")
c.close()