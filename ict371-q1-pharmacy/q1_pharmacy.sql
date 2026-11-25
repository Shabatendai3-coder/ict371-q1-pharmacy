-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Student: Patience Shaba (202409214) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1, public;

-- (a) Tables, constraints and seed medicines ------------------------------
CREATE TABLE medicines (
  medicine_id   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL
);
CREATE TABLE stock_audit (
  audit_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INTEGER NOT NULL,
  new_qty     INTEGER NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INTEGER NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL
);
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 8.00, 15),
 ('Ibuprofen 200mg',   3.75, 40),
 ('Cough Syrup 100ml', 12.00, 11);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive whole number.';
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Medicine % does not exist.', p_medicine_id;
  END IF;
  RETURN ROUND(v_price * p_quantity, 2);
END; $$;

-- (c) Procedure: validate first, then insert the sale and deduct stock once
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive whole number.';
  END IF;
  IF p_sold_on IS NULL THEN RAISE EXCEPTION 'Sale date is required.'; END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- row lock
  IF NOT FOUND THEN RAISE EXCEPTION 'Medicine % does not exist.', p_medicine_id; END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: % available, % requested.', v_stock, p_quantity;
  END IF;
  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
END; $$;

-- (d) Trigger: audit only real stock changes ---------------------------------
CREATE OR REPLACE FUNCTION fn_trg_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
      VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_medicines_stock_audit
  AFTER UPDATE ON medicines FOR EACH ROW
  WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
  EXECUTE FUNCTION fn_trg_stock_audit();

-- (a, continued) Six valid sales loaded through the procedure ------------------
CALL pr_record_sale(1, 10, DATE '2026-11-20');
CALL pr_record_sale(2,  6, DATE '2026-11-20');
CALL pr_record_sale(3,  5, DATE '2026-11-21');
CALL pr_record_sale(1, 20, DATE '2026-11-21');
CALL pr_record_sale(4,  2, DATE '2026-11-24');
CALL pr_record_sale(2,  3, DATE '2026-11-24');

-- Tests for (b), (c), (d)
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown medicine): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_sale_value(1, 0);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (bad quantity): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_sale(1, 9999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (oversell): %', SQLERRM; END $$;
SELECT medicine_id, stock_qty FROM medicines ORDER BY 1;      -- unchanged by the failed sale
SELECT COUNT(*) AS sales_rows FROM sales;                      -- still 6
UPDATE medicines SET unit_price = 2.60 WHERE medicine_id = 1;  -- no stock change: no audit row
SELECT * FROM stock_audit ORDER BY audit_id;                   -- one row per stock change

-- (e) View -------------------------------------------------------------------
CREATE VIEW v_low_stock AS
  SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
  FROM medicines WHERE stock_qty < 10;
SELECT * FROM v_low_stock ORDER BY medicine_id;                -- queried after the sales

-- (f) Index -------------------------------------------------------------------
-- Equality on medicine_id first, then a range on sold_on: one B-tree scan reads
-- exactly one medicine's sales in date order without scanning the whole table.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;   -- tables are tiny; this only forces the plan to show the index
EXPLAIN SELECT sale_id, quantity, unit_price, sold_on
FROM sales WHERE medicine_id = 1 AND sold_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-24';
RESET enable_seqscan;

-- (g) Scheduled job -------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql SET search_path = q1, public AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'Day is required.'; END IF;
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE                  -- replace, never add
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END; $$;

CALL pr_refresh_sales(DATE '2026-11-20');
CALL pr_refresh_sales(DATE '2026-11-21');
CALL pr_refresh_sales(DATE '2026-11-24');
CALL pr_refresh_sales(DATE '2026-11-20');             -- rerun: totals must stay the same
SELECT * FROM daily_sales ORDER BY sales_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *', $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q1_refresh_sales';
