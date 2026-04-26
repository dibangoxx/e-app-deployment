-- =============================================================================
-- FlashInfo E-Commerce — Aurora PostgreSQL Schema
-- Covers: products, inventory, customers, orders, documents, reviews, analytics
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- PRODUCTS & CATALOG
-- =============================================================================

CREATE TYPE product_status AS ENUM ('active', 'draft', 'discontinued');
CREATE TYPE product_category AS ENUM (
  'living_room', 'kitchen_dining', 'bedroom', 'bathroom',
  'outdoor', 'lighting', 'storage', 'decor', 'textiles'
);

CREATE TABLE products (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku             TEXT UNIQUE NOT NULL,
  name            TEXT NOT NULL,
  slug            TEXT UNIQUE NOT NULL,
  description     TEXT,
  short_desc      TEXT,
  category        product_category NOT NULL,
  subcategory     TEXT,
  brand           TEXT,
  status          product_status NOT NULL DEFAULT 'draft',
  price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  compare_at_price NUMERIC(10,2),
  cost            NUMERIC(10,2),
  weight_grams    INT,
  dimensions      JSONB,           -- {length, width, height, unit}
  images          JSONB NOT NULL DEFAULT '[]',  -- [{url, alt, position}]
  tags            TEXT[],
  meta_title      TEXT,
  meta_description TEXT,
  attributes      JSONB NOT NULL DEFAULT '{}',  -- {color, material, style}
  is_featured     BOOLEAN NOT NULL DEFAULT false,
  is_new_arrival  BOOLEAN NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_products_category   ON products(category) WHERE status = 'active';
CREATE INDEX idx_products_slug       ON products(slug);
CREATE INDEX idx_products_sku        ON products(sku);
CREATE INDEX idx_products_featured   ON products(is_featured) WHERE status = 'active';
CREATE INDEX idx_products_tags       ON products USING GIN(tags);
CREATE INDEX idx_products_attributes ON products USING GIN(attributes);

-- Inventory management
CREATE TABLE inventory (
  product_id     UUID PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  quantity       INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  reserved       INT NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  reorder_point  INT NOT NULL DEFAULT 5,
  reorder_qty    INT NOT NULL DEFAULT 50,
  warehouse_location TEXT,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT available_non_negative CHECK (quantity >= reserved)
);

-- Product variants (size, color)
CREATE TABLE product_variants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  sku         TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  price       NUMERIC(10,2),
  attributes  JSONB NOT NULL DEFAULT '{}',  -- {color: "Sage", size: "Large"}
  quantity    INT NOT NULL DEFAULT 0,
  reserved    INT NOT NULL DEFAULT 0,
  position    INT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_variants_product ON product_variants(product_id);

-- =============================================================================
-- CUSTOMERS & IDENTITY
-- =============================================================================

CREATE TYPE customer_role AS ENUM ('customer', 'staff', 'admin');

CREATE TABLE customers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cognito_sub     TEXT UNIQUE NOT NULL,
  email           TEXT UNIQUE NOT NULL,
  given_name      TEXT NOT NULL,
  family_name     TEXT NOT NULL,
  phone           TEXT,
  role            customer_role NOT NULL DEFAULT 'customer',
  date_of_birth   DATE,
  accepts_marketing BOOLEAN NOT NULL DEFAULT false,
  total_spent     NUMERIC(12,2) NOT NULL DEFAULT 0,
  orders_count    INT NOT NULL DEFAULT 0,
  notes           TEXT,
  tags            TEXT[],
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at   TIMESTAMPTZ
);

CREATE INDEX idx_customers_email       ON customers(email);
CREATE INDEX idx_customers_cognito_sub ON customers(cognito_sub);
CREATE INDEX idx_customers_role        ON customers(role);
CREATE INDEX idx_customers_last_login  ON customers(last_login_at);

CREATE TABLE customer_addresses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id    UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  first_name     TEXT NOT NULL,
  last_name      TEXT NOT NULL,
  company        TEXT,
  address_line1  TEXT NOT NULL,
  address_line2  TEXT,
  city           TEXT NOT NULL,
  state_province TEXT,
  postal_code    TEXT NOT NULL,
  country_code   CHAR(2) NOT NULL DEFAULT 'US',
  phone          TEXT,
  is_default     BOOLEAN NOT NULL DEFAULT false,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_addresses_customer ON customer_addresses(customer_id);

-- =============================================================================
-- SHOPPING CART & WISHLIST
-- =============================================================================

CREATE TABLE carts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID REFERENCES customers(id) ON DELETE SET NULL,
  session_id  TEXT,
  currency    CHAR(3) NOT NULL DEFAULT 'USD',
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_carts_customer   ON carts(customer_id);
CREATE INDEX idx_carts_session    ON carts(session_id);

CREATE TABLE cart_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id     UUID NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  product_id  UUID NOT NULL REFERENCES products(id),
  variant_id  UUID REFERENCES product_variants(id),
  quantity    INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL,
  added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cart_items_cart ON cart_items(cart_id);

CREATE TABLE wishlists (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (customer_id, product_id)
);

-- =============================================================================
-- ORDERS & FULFILLMENT
-- =============================================================================

CREATE TYPE order_status AS ENUM (
  'pending', 'payment_pending', 'paid', 'processing',
  'shipped', 'delivered', 'cancelled', 'refunded', 'on_hold'
);

CREATE TYPE fulfillment_status AS ENUM (
  'unfulfilled', 'partial', 'fulfilled', 'returned'
);

CREATE TABLE orders (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number        SERIAL UNIQUE,
  customer_id         UUID NOT NULL REFERENCES customers(id),
  status              order_status NOT NULL DEFAULT 'pending',
  fulfillment_status  fulfillment_status NOT NULL DEFAULT 'unfulfilled',

  -- Financials
  subtotal            NUMERIC(10,2) NOT NULL,
  discount_total      NUMERIC(10,2) NOT NULL DEFAULT 0,
  shipping_total      NUMERIC(10,2) NOT NULL DEFAULT 0,
  tax_total           NUMERIC(10,2) NOT NULL DEFAULT 0,
  total               NUMERIC(10,2) NOT NULL,
  currency            CHAR(3) NOT NULL DEFAULT 'USD',
  refunded_amount     NUMERIC(10,2) NOT NULL DEFAULT 0,

  -- Addresses (snapshot at time of order)
  shipping_address    JSONB NOT NULL,
  billing_address     JSONB,

  -- Payment
  payment_intent_id   TEXT,
  payment_method      JSONB,

  -- Shipping
  shipping_method     TEXT,
  tracking_number     TEXT,
  shipped_at          TIMESTAMPTZ,
  delivered_at        TIMESTAMPTZ,
  estimated_delivery  DATE,

  -- Step Functions execution ARN
  sfn_execution_arn   TEXT,

  -- Metadata
  source              TEXT DEFAULT 'web',
  note                TEXT,
  staff_note          TEXT,
  tags                TEXT[],
  promo_code          TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  cancelled_at        TIMESTAMPTZ,
  cancel_reason       TEXT
);

CREATE INDEX idx_orders_customer    ON orders(customer_id);
CREATE INDEX idx_orders_status      ON orders(status);
CREATE INDEX idx_orders_created_at  ON orders(created_at DESC);
CREATE INDEX idx_orders_number      ON orders(order_number);
CREATE INDEX idx_orders_payment_intent ON orders(payment_intent_id);

CREATE TABLE order_items (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id      UUID NOT NULL REFERENCES products(id),
  variant_id      UUID REFERENCES product_variants(id),
  sku             TEXT NOT NULL,
  name            TEXT NOT NULL,
  quantity        INT NOT NULL CHECK (quantity > 0),
  unit_price      NUMERIC(10,2) NOT NULL,
  discount_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  tax_amount      NUMERIC(10,2) NOT NULL DEFAULT 0,
  total           NUMERIC(10,2) NOT NULL,
  fulfilled_qty   INT NOT NULL DEFAULT 0,
  returned_qty    INT NOT NULL DEFAULT 0,
  properties      JSONB DEFAULT '{}'
);

CREATE INDEX idx_order_items_order ON order_items(order_id);

-- =============================================================================
-- PROMOTIONS & DISCOUNTS
-- =============================================================================

CREATE TYPE discount_type AS ENUM ('percentage', 'fixed_amount', 'free_shipping');

CREATE TABLE promo_codes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT UNIQUE NOT NULL,
  description     TEXT,
  discount_type   discount_type NOT NULL,
  discount_value  NUMERIC(10,2) NOT NULL,
  minimum_order   NUMERIC(10,2),
  usage_limit     INT,
  usage_count     INT NOT NULL DEFAULT 0,
  customer_limit  INT DEFAULT 1,
  starts_at       TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_promo_codes_code ON promo_codes(code) WHERE is_active = true;

-- =============================================================================
-- DOCUMENTS
-- =============================================================================

CREATE TYPE document_type AS ENUM (
  'order_invoice', 'return_label', 'product_manual',
  'warranty_card', 'receipt', 'other'
);

CREATE TABLE documents (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     UUID REFERENCES customers(id),
  order_id        UUID REFERENCES orders(id),
  type            document_type NOT NULL,
  title           TEXT NOT NULL,
  s3_key          TEXT NOT NULL,
  s3_bucket       TEXT NOT NULL,
  file_size_bytes BIGINT,
  mime_type       TEXT,
  retention_class TEXT NOT NULL DEFAULT 'standard',
  legal_hold      BOOLEAN NOT NULL DEFAULT false,
  checksum_sha256 TEXT,
  tags            JSONB NOT NULL DEFAULT '{}',
  uploaded_by     UUID REFERENCES customers(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_documents_customer ON documents(customer_id);
CREATE INDEX idx_documents_order    ON documents(order_id);
CREATE INDEX idx_documents_type     ON documents(type);

-- =============================================================================
-- REVIEWS & RATINGS
-- =============================================================================

CREATE TYPE review_status AS ENUM ('pending', 'approved', 'rejected', 'spam');

CREATE TABLE reviews (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES customers(id),
  order_id    UUID REFERENCES orders(id),
  rating      SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title       TEXT,
  body        TEXT,
  status      review_status NOT NULL DEFAULT 'pending',
  helpful_count INT NOT NULL DEFAULT 0,
  verified_purchase BOOLEAN NOT NULL DEFAULT false,
  media       JSONB DEFAULT '[]',   -- uploaded review photos
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (product_id, customer_id, order_id)
);

CREATE INDEX idx_reviews_product ON reviews(product_id) WHERE status = 'approved';
CREATE INDEX idx_reviews_customer ON reviews(customer_id);

-- Materialized view for product ratings (refresh nightly)
CREATE MATERIALIZED VIEW product_rating_summary AS
SELECT
  product_id,
  COUNT(*) AS review_count,
  ROUND(AVG(rating)::NUMERIC, 2) AS avg_rating,
  COUNT(*) FILTER (WHERE rating = 5) AS five_star,
  COUNT(*) FILTER (WHERE rating = 4) AS four_star,
  COUNT(*) FILTER (WHERE rating = 3) AS three_star,
  COUNT(*) FILTER (WHERE rating = 2) AS two_star,
  COUNT(*) FILTER (WHERE rating = 1) AS one_star
FROM reviews
WHERE status = 'approved'
GROUP BY product_id;

CREATE UNIQUE INDEX ON product_rating_summary(product_id);

-- =============================================================================
-- NOTIFICATIONS
-- =============================================================================

CREATE TYPE notification_type AS ENUM (
  'order_confirmed', 'order_shipped', 'order_delivered',
  'order_cancelled', 'review_approved', 'promo_offer',
  'restock_alert', 'password_reset', 'welcome'
);

CREATE TABLE notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  type        notification_type NOT NULL,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  data        JSONB DEFAULT '{}',
  is_read     BOOLEAN NOT NULL DEFAULT false,
  sent_at     TIMESTAMPTZ,
  read_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_customer ON notifications(customer_id, is_read, created_at DESC);

-- =============================================================================
-- ANALYTICS — Client Health / Product Health Scores
-- =============================================================================

CREATE TABLE product_health_scores (
  product_id          UUID PRIMARY KEY REFERENCES products(id),
  health_score        NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (health_score BETWEEN 0 AND 100),
  units_sold_30d      INT NOT NULL DEFAULT 0,
  revenue_30d         NUMERIC(12,2) NOT NULL DEFAULT 0,
  view_count_30d      INT NOT NULL DEFAULT 0,
  conversion_rate     NUMERIC(5,4) NOT NULL DEFAULT 0,
  avg_rating          NUMERIC(3,2),
  return_rate         NUMERIC(5,4) NOT NULL DEFAULT 0,
  restock_needed      BOOLEAN NOT NULL DEFAULT false,
  score_breakdown     JSONB NOT NULL DEFAULT '{}',
  calculated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_metrics (
  date            DATE NOT NULL,
  total_orders    INT NOT NULL DEFAULT 0,
  total_revenue   NUMERIC(12,2) NOT NULL DEFAULT 0,
  avg_order_value NUMERIC(10,2) NOT NULL DEFAULT 0,
  new_customers   INT NOT NULL DEFAULT 0,
  returning_customers INT NOT NULL DEFAULT 0,
  items_sold      INT NOT NULL DEFAULT 0,
  cancelled_orders INT NOT NULL DEFAULT 0,
  refund_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (date)
);

-- =============================================================================
-- AUDIT LOG
-- =============================================================================

CREATE TABLE audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name  TEXT NOT NULL,
  record_id   UUID NOT NULL,
  action      TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  changed_by  UUID REFERENCES customers(id),
  old_values  JSONB,
  new_values  JSONB,
  ip_address  INET,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_record   ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_log_created  ON audit_log(created_at DESC);

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- Update updated_at automatically
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DO $$ DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY['products','customers','orders','reviews'])
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION update_updated_at()',
      t, t
    );
  END LOOP;
END $$;

-- Update customer totals on order status change
CREATE OR REPLACE FUNCTION sync_customer_order_totals()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status IN ('paid', 'delivered', 'shipped') AND
     (OLD.status IS NULL OR OLD.status NOT IN ('paid', 'delivered', 'shipped')) THEN
    UPDATE customers
    SET
      total_spent  = total_spent + NEW.total,
      orders_count = orders_count + 1,
      updated_at   = NOW()
    WHERE id = NEW.customer_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_customer_sync
  AFTER INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION sync_customer_order_totals();

-- =============================================================================
-- SEED DATA — Sample products
-- =============================================================================

INSERT INTO products (sku, name, slug, description, category, price, compare_at_price,
                      status, images, tags, is_featured, is_new_arrival, attributes)
VALUES
  ('HG-CHAIR-001', 'Woven Accent Chair', 'woven-accent-chair',
   'Hand-woven rattan accent chair with natural finish. Sturdy steel frame.',
   'living_room', 349.00, NULL, 'active',
   '[{"url":"/images/woven-chair-1.jpg","alt":"Woven Accent Chair","position":0}]',
   ARRAY['chair','rattan','accent','natural'], true, false,
   '{"color":"Natural","material":"Rattan","assembly":"Required"}'),

  ('HG-TABLE-001', 'Teak Coffee Table', 'teak-coffee-table',
   'Solid teak coffee table with lower shelf. Water-resistant finish.',
   'living_room', 529.00, NULL, 'active',
   '[{"url":"/images/teak-table-1.jpg","alt":"Teak Coffee Table","position":0}]',
   ARRAY['table','teak','coffee table','wood'], true, false,
   '{"color":"Teak","material":"Solid Teak","finish":"Oil"}'),

  ('HG-DUVET-001', 'Linen Duvet Cover', 'linen-duvet-cover',
   '100% Belgian linen duvet cover. Gets softer with every wash.',
   'bedroom', 159.00, NULL, 'active',
   '[{"url":"/images/linen-duvet-1.jpg","alt":"Linen Duvet","position":0}]',
   ARRAY['linen','bedding','duvet','bedroom'], false, true,
   '{"color":"Oatmeal","material":"100% Belgian Linen","sizes":["Queen","King"]}'),

  ('HG-CANDLE-001', 'Soy Wax Candle Set', 'soy-wax-candle-set',
   'Set of 3 hand-poured soy candles. Scents: Cedarwood, Lavender, Eucalyptus.',
   'decor', 42.00, 58.00, 'active',
   '[{"url":"/images/candle-set-1.jpg","alt":"Soy Candle Set","position":0}]',
   ARRAY['candle','soy','home fragrance','set'], false, false,
   '{"scents":["Cedarwood","Lavender","Eucalyptus"],"burn_time":"40hrs each"}'),

  ('HG-PLANTER-001', 'Ceramic Planter Set', 'ceramic-planter-set',
   'Set of 3 handcrafted ceramic planters with drainage holes.',
   'decor', 65.00, NULL, 'active',
   '[{"url":"/images/planters-1.jpg","alt":"Ceramic Planters","position":0}]',
   ARRAY['planter','ceramic','plants','decor'], true, true,
   '{"color":"Sage","material":"Ceramic","set_size":"3"}'),

  ('HG-BOARD-001', 'Marble Serving Board', 'marble-serving-board',
   'White Carrara marble serving board with walnut handle.',
   'kitchen_dining', 89.00, NULL, 'active',
   '[{"url":"/images/marble-board-1.jpg","alt":"Marble Board","position":0}]',
   ARRAY['marble','kitchen','serving board','entertaining'], false, false,
   '{"color":"White/Walnut","material":"Carrara Marble + Walnut","dimensions":"14x8in"}'),

  ('HG-THROW-001', 'Merino Wool Throw', 'merino-wool-throw',
   'Extra-fine merino wool throw blanket. 130x170cm.',
   'bedroom', 128.00, NULL, 'active',
   '[{"url":"/images/merino-throw-1.jpg","alt":"Merino Throw","position":0}]',
   ARRAY['throw','merino','wool','blanket'], false, false,
   '{"color":"Charcoal","material":"100% Merino Wool","size":"130x170cm"}'),

  ('HG-BATH-001', 'Bamboo Bath Set', 'bamboo-bath-set',
   'Bamboo bath accessory set: toothbrush holder, soap dispenser, tumbler, tray.',
   'bathroom', 79.00, 99.00, 'active',
   '[{"url":"/images/bamboo-bath-1.jpg","alt":"Bamboo Bath Set","position":0}]',
   ARRAY['bamboo','bathroom','eco','set'], false, false,
   '{"material":"Bamboo","pieces":"4","color":"Natural"}');

-- Seed inventory
INSERT INTO inventory (product_id, quantity, reserved, reorder_point, reorder_qty)
SELECT id, 50, 0, 10, 100 FROM products;

-- =============================================================================
-- GRANTS (app user gets minimal permissions)
-- =============================================================================

CREATE ROLE flashinfo_app WITH LOGIN PASSWORD 'CHANGE_ME_IN_SECRETS_MANAGER';

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO flashinfo_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO flashinfo_app;
GRANT SELECT ON product_rating_summary TO flashinfo_app;

-- Read-only role for analytics
CREATE ROLE flashinfo_readonly WITH LOGIN PASSWORD 'CHANGE_ME_IN_SECRETS_MANAGER';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO flashinfo_readonly;
GRANT SELECT ON product_rating_summary TO flashinfo_readonly;
