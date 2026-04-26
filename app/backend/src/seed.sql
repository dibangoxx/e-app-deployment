-- =============================================================================
-- FlashInfo — Local Development Seed Data
-- Runs AFTER schema.sql via docker-entrypoint-initdb.d
-- =============================================================================

-- Only seed if products table is empty
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM products) > 0 THEN
    RAISE NOTICE 'Products already seeded, skipping.';
    RETURN;
  END IF;

  -- Products are already inserted by schema.sql
  -- This file adds local dev users and test data

  -- ── Dev admin user (password: Admin1234!) ─────────────────────────────────
  INSERT INTO customers (id, cognito_sub, email, given_name, family_name, role)
  VALUES (
    '00000000-0000-0000-0000-000000000001',
    'local-admin-dev',
    'admin@flashinfo.local',
    'Admin',
    'User',
    'admin'
  ) ON CONFLICT DO NOTHING;

  -- Local credentials table (only needed locally — Cognito handles prod auth)
  CREATE TABLE IF NOT EXISTS local_credentials (
    customer_id UUID PRIMARY KEY REFERENCES customers(id),
    hash TEXT NOT NULL
  );

  -- bcrypt hash of "Admin1234!" (cost 12)
  INSERT INTO local_credentials (customer_id, hash)
  VALUES (
    '00000000-0000-0000-0000-000000000001',
    '$2a$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LfEJZmXqiMFzDlbBy'
  ) ON CONFLICT DO NOTHING;

  -- ── Test customer (password: Test1234!) ────────────────────────────────────
  INSERT INTO customers (id, cognito_sub, email, given_name, family_name)
  VALUES (
    '00000000-0000-0000-0000-000000000002',
    'local-customer-dev',
    'customer@flashinfo.local',
    'Test',
    'Customer'
  ) ON CONFLICT DO NOTHING;

  INSERT INTO local_credentials (customer_id, hash)
  VALUES (
    '00000000-0000-0000-0000-000000000002',
    '$2a$12$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi'
  ) ON CONFLICT DO NOTHING;

  -- ── Sample customer address ────────────────────────────────────────────────
  INSERT INTO customer_addresses (customer_id, first_name, last_name, address_line1, city, state_province, postal_code, country_code, is_default)
  VALUES (
    '00000000-0000-0000-0000-000000000002',
    'Test', 'Customer', '123 Main Street', 'Austin', 'TX', '78701', 'US', true
  ) ON CONFLICT DO NOTHING;

  -- ── Sample order ───────────────────────────────────────────────────────────
  INSERT INTO orders (id, customer_id, status, subtotal, shipping_total, tax_total, total, shipping_address)
  VALUES (
    '00000000-0000-0000-0000-000000000010',
    '00000000-0000-0000-0000-000000000002',
    'delivered',
    349.00, 0.00, 27.92, 376.92,
    '{"first_name":"Test","last_name":"Customer","address_line1":"123 Main Street","city":"Austin","state_province":"TX","postal_code":"78701","country_code":"US"}'
  ) ON CONFLICT DO NOTHING;

  -- Get first product id
  WITH first_product AS (SELECT id, sku, name, price FROM products LIMIT 1)
  INSERT INTO order_items (order_id, product_id, sku, name, quantity, unit_price, total)
  SELECT
    '00000000-0000-0000-0000-000000000010',
    id, sku, name, 1, price, price
  FROM first_product
  ON CONFLICT DO NOTHING;

  -- ── Refresh materialized view ──────────────────────────────────────────────
  REFRESH MATERIALIZED VIEW product_rating_summary;

  RAISE NOTICE 'Development seed data applied successfully.';
END $$;
