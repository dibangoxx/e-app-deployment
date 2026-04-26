'use strict';

const express   = require('express');
const { query: db, withTransaction } = require('../config/db');
const { events, sfn } = require('../config/aws');
const { PutEventsCommand }     = require('@aws-sdk/client-eventbridge');
const { StartExecutionCommand } = require('@aws-sdk/client-sfn');
const { authenticate } = require('../middleware/auth');
const logger    = require('../config/logger');
const { v4: uuidv4 } = require('uuid');

const router = express.Router();

const EVENT_BUS  = process.env.EVENT_BUS_NAME || 'flashinfo-local';
const SFN_ARN    = process.env.CHECKOUT_SFN_ARN || '';

// GET /api/v1/orders — customer's own orders
router.get('/', authenticate, async (req, res, next) => {
  try {
    const { page = 1, limit = 10 } = req.query;
    const offset = (Math.max(1, Number(page)) - 1) * Math.min(50, Number(limit));

    const { rows } = await db(`
      SELECT o.*,
        json_agg(json_build_object(
          'id',         oi.id,
          'product_id', oi.product_id,
          'name',       oi.name,
          'quantity',   oi.quantity,
          'unit_price', oi.unit_price,
          'total',      oi.total
        )) AS items
      FROM orders o
      JOIN order_items oi ON oi.order_id = o.id
      WHERE o.customer_id = $1
      GROUP BY o.id
      ORDER BY o.created_at DESC
      LIMIT $2 OFFSET $3
    `, [req.user.sub, Number(limit), offset]);

    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
});

// GET /api/v1/orders/:id
router.get('/:id', authenticate, async (req, res, next) => {
  try {
    const { rows } = await db(`
      SELECT o.*,
        json_agg(json_build_object(
          'id', oi.id, 'product_id', oi.product_id,
          'name', oi.name, 'sku', oi.sku,
          'quantity', oi.quantity, 'unit_price', oi.unit_price, 'total', oi.total
        )) AS items
      FROM orders o
      JOIN order_items oi ON oi.order_id = o.id
      WHERE o.id = $1 AND o.customer_id = $2
      GROUP BY o.id
    `, [req.params.id, req.user.sub]);

    if (!rows[0]) return res.status(404).json({ error: 'Order not found' });
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

// POST /api/v1/orders/checkout — places order + triggers Step Functions
router.post('/checkout', authenticate, async (req, res, next) => {
  try {
    const { items, shipping_address, payment_method_id, promo_code } = req.body;

    if (!items?.length) return res.status(400).json({ error: 'Cart is empty' });
    if (!shipping_address) return res.status(400).json({ error: 'Shipping address required' });

    // Fetch product prices from DB (never trust client prices)
    const productIds = items.map(i => i.product_id);
    const { rows: products } = await db(
      `SELECT p.id, p.name, p.sku, p.price, inv.quantity - inv.reserved AS available
       FROM products p JOIN inventory inv ON inv.product_id = p.id
       WHERE p.id = ANY($1::uuid[]) AND p.status = 'active'`,
      [productIds]
    );

    const productMap = Object.fromEntries(products.map(p => [p.id, p]));

    // Validate stock and compute totals
    let subtotal = 0;
    const validatedItems = [];

    for (const item of items) {
      const product = productMap[item.product_id];
      if (!product) return res.status(400).json({ error: `Product ${item.product_id} not found or unavailable` });
      if (product.available < item.quantity) {
        return res.status(409).json({ error: `Insufficient stock for "${product.name}"` });
      }
      const lineTotal = product.price * item.quantity;
      subtotal += lineTotal;
      validatedItems.push({ ...item, product, unit_price: product.price, total: lineTotal });
    }

    const shipping = subtotal >= 75 ? 0 : 8.99;
    const tax      = parseFloat((subtotal * 0.08).toFixed(2));
    const total    = parseFloat((subtotal + shipping + tax).toFixed(2));

    const order = await withTransaction(async (client) => {
      const orderId = uuidv4();

      // Create order
      const { rows: [o] } = await client.query(`
        INSERT INTO orders
          (id, customer_id, status, subtotal, shipping_total, tax_total, total,
           shipping_address, payment_method, promo_code)
        VALUES ($1,$2,'pending',$3,$4,$5,$6,$7,$8,$9)
        RETURNING *
      `, [orderId, req.user.sub, subtotal, shipping, tax, total,
          JSON.stringify(shipping_address),
          JSON.stringify({ id: payment_method_id }),
          promo_code || null]);

      // Insert line items
      for (const item of validatedItems) {
        await client.query(`
          INSERT INTO order_items (order_id, product_id, sku, name, quantity, unit_price, total)
          VALUES ($1,$2,$3,$4,$5,$6,$7)
        `, [orderId, item.product_id, item.product.sku, item.product.name,
            item.quantity, item.unit_price, item.total]);
      }

      return o;
    });

    // Kick off Step Functions checkout workflow (fire-and-forget locally)
    if (SFN_ARN) {
      await sfn.send(new StartExecutionCommand({
        stateMachineArn: SFN_ARN,
        name:  `order-${order.id}-${Date.now()}`,
        input: JSON.stringify({
          orderId:         order.id,
          customerId:      req.user.sub,
          customerEmail:   req.user.email,
          items:           validatedItems.map(i => ({ product_id: i.product_id, quantity: i.quantity })),
          total,
          paymentMethodId: payment_method_id,
        }),
      })).catch(err => logger.warn({ err }, 'SFN start failed — continuing'));
    }

    // Emit OrderPlaced domain event
    await events.send(new PutEventsCommand({
      Entries: [{
        EventBusName: EVENT_BUS,
        Source:       'flashinfo.orders',
        DetailType:   'OrderPlaced',
        Detail:       JSON.stringify({ orderId: order.id, customerId: req.user.sub, total }),
      }],
    })).catch(err => logger.warn({ err }, 'EventBridge emit failed'));

    logger.info({ orderId: order.id, total }, 'Order placed');
    res.status(201).json(order);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
