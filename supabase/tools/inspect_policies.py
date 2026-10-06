import io
import psycopg2

c = psycopg2.connect(host="127.0.0.1", port=5433, user="postgres",
                     dbname="madjana_test", password="", sslmode="disable")
cur = c.cursor()
cur.execute(
    "SELECT tablename, policyname, "
    "       coalesce(qual, with_check) "
    "  FROM pg_policies "
    " WHERE schemaname = 'public' "
    "   AND tablename = ANY(%s) "
    "   AND policyname LIKE '%%_read' "
    " ORDER BY tablename, policyname",
    (["payments", "expenses", "revenue", "opening_balances",
      "inventory_items", "stock_adjustments"],))
out = [f"{t}.{p}\n     {q}" for t, p, q in cur.fetchall()]
cur.execute("SELECT count(*) FROM pg_policies WHERE schemaname='public'")
out.append(f"total policies: {cur.fetchone()[0]}")
c.close()
io.open(r"C:\Users\MTC\Desktop\madjana\sp.txt", "w",
        encoding="utf-8").write("\n".join(out))