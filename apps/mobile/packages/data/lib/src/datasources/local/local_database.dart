CREATE TABLE farms (
    id INTEGER PRIMARY KEY AUTOINCREMENT, 
    farm_name TEXT, 
    farm_code TEXT, 
    farm_type TEXT, 
    created_at TEXT, 
    updated_at TEXT,
    feed_bag_weight_kg REAL NOT NULL DEFAULT 50.0,
    trays_per_bundle INTEGER NOT NULL DEFAULT 100 CHECK (trays_per_bundle > 0)
  );