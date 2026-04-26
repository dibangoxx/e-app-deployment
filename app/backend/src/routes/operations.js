'use strict';

const express = require('express');
const { query: db } = require('../config/db');
const { authenticate, requireRole } = require('../middleware/auth');

const router = express.Router();

router.use(authenticate, requireRole('admin'));

router.get('/summary', async (req, res, next) => {
  try {
    const [kpis, fulfillment, customers] = await Promise.all([
      db(`
        SELECT
          COALESCE(SUM(total) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days'), 0)::NUMERIC(12,2) AS revenue_30d,
          COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::INT AS orders_30d,
          COALESCE(AVG(total) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days'), 0)::NUMERIC(12,2) AS avg_order_value_30d,
          COUNT(*) FILTER (WHERE status IN ('pending','payment_pending','processing','on_hold'))::INT AS open_orders,
          COUNT(*) FILTER (WHERE status = 'shipped')::INT AS shipped_not_delivered
        FROM orders
      `),
      db(`
        SELECT
          COUNT(*) FILTER (WHERE quantity - reserved <= reorder_point)::INT AS low_stock_skus,
          COUNT(*) FILTER (WHERE quantity - reserved <= 0)::INT AS out_of_stock_skus,
          COALESCE(SUM(quantity - reserved), 0)::INT AS available_units
        FROM inventory
      `),
      db(`
        SELECT
          COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '30 days')::INT AS new_customers_30d,
          COUNT(*)::INT AS total_customers,
          COALESCE(SUM(total_spent), 0)::NUMERIC(12,2) AS lifetime_revenue
        FROM customers
      `),
    ]);

    res.json({
      kpis: kpis.rows[0],
      fulfillment: fulfillment.rows[0],
      customers: customers.rows[0],
      generated_at: new Date().toISOString(),
    });
  } catch (err) {
    next(err);
  }
});

router.get('/inventory/low-stock', async (req, res, next) => {
  try {
    const limit = Math.min(200, Math.max(1, Number(req.query.limit || 50)));
    const { rows } = await db(
      `
      SELECT
        p.id,
        p.sku,
        p.name,
        p.category,
        i.quantity,
        i.reserved,
        (i.quantity - i.reserved) AS available,
        i.reorder_point,
        i.reorder_qty,
        CASE
          WHEN i.quantity - i.reserved <= 0 THEN 'critical'
          WHEN i.quantity - i.reserved <= i.reorder_point THEN 'warning'
          ELSE 'healthy'
        END AS stock_status
      FROM inventory i
      JOIN products p ON p.id = i.product_id
      WHERE p.status = 'active'
      ORDER BY (i.quantity - i.reserved) ASC, p.created_at DESC
      LIMIT $1
      `,
      [limit]
    );

    res.json({ data: rows, count: rows.length });
  } catch (err) {
    next(err);
  }
});

router.get('/orders/pipeline', async (req, res, next) => {
  try {
    const { rows: statusRows } = await db(`
      SELECT status, COUNT(*)::INT AS count, COALESCE(SUM(total), 0)::NUMERIC(12,2) AS gross_value
      FROM orders
      GROUP BY status
      ORDER BY count DESC
    `);

    const { rows: recentRows } = await db(`
      SELECT
        o.id,
        o.order_number,
        o.status,
        o.fulfillment_status,
        o.total,
        o.created_at,
        c.email,
        c.given_name,
        c.family_name
      FROM orders o
      JOIN customers c ON c.id = o.customer_id
      ORDER BY o.created_at DESC
      LIMIT 25
    `);

    res.json({ by_status: statusRows, recent: recentRows });
  } catch (err) {
    next(err);
  }
});

router.get('/customers/segments', async (req, res, next) => {
  try {
    const { rows } = await db(`
      SELECT
        CASE
          WHEN total_spent >= 5000 THEN 'vip'
          WHEN total_spent >= 1000 THEN 'repeat_high_value'
          WHEN orders_count >= 3 THEN 'repeat'
          WHEN orders_count >= 1 THEN 'new_buyer'
          ELSE 'lead'
        END AS segment,
        COUNT(*)::INT AS customers,
        COALESCE(AVG(total_spent), 0)::NUMERIC(12,2) AS avg_spend,
        COALESCE(SUM(total_spent), 0)::NUMERIC(12,2) AS total_spend
      FROM customers
      GROUP BY 1
      ORDER BY total_spend DESC
    `);

    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
});

router.get('/procurement/recommendations', async (req, res, next) => {
  try {
    const { rows } = await db(`
      WITH sales_30d AS (
        SELECT oi.product_id, COALESCE(SUM(oi.quantity), 0)::INT AS sold_30d
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        WHERE o.created_at >= NOW() - INTERVAL '30 days'
        GROUP BY oi.product_id
      )
      SELECT
        p.id,
        p.sku,
        p.name,
        p.category,
        i.quantity,
        i.reserved,
        (i.quantity - i.reserved) AS available,
        i.reorder_point,
        i.reorder_qty,
        COALESCE(s.sold_30d, 0) AS sold_30d,
        GREATEST(i.reorder_qty, COALESCE(s.sold_30d, 0) - (i.quantity - i.reserved), 0)::INT AS suggested_po_qty
      FROM inventory i
      JOIN products p ON p.id = i.product_id
      LEFT JOIN sales_30d s ON s.product_id = p.id
      WHERE p.status = 'active'
        AND (i.quantity - i.reserved) <= i.reorder_point
      ORDER BY suggested_po_qty DESC, sold_30d DESC
      LIMIT 100
    `);

    res.json({ data: rows, generated_at: new Date().toISOString() });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
