'use strict';

const express = require('express');
const { query: dbQuery } = require('../config/db');
const redis  = require('../config/redis');
const logger = require('../config/logger');
const { authenticate, requireRole } = require('../middleware/auth');

const router = express.Router();
const CACHE_TTL = 300; // 5 minutes

// GET /api/v1/products — list with filter, sort, pagination
router.get('/', async (req, res, next) => {
  try {
    const {
      category, min_price, max_price, tag,
      sort = 'created_at', order = 'desc',
      page = 1, limit = 20, featured, new_arrival,
    } = req.query;

    const cacheKey = `products:list:${JSON.stringify(req.query)}`;
    const cached = await redis.get(cacheKey).catch(() => null);
    if (cached) return res.json(JSON.parse(cached));

    const conditions = ["p.status = 'active'"];
    const params = [];
    let i = 1;

    if (category)    { conditions.push(`p.category = $${i++}`);    params.push(category); }
    if (min_price)   { conditions.push(`p.price >= $${i++}`);      params.push(Number(min_price)); }
    if (max_price)   { conditions.push(`p.price <= $${i++}`);      params.push(Number(max_price)); }
    if (tag)         { conditions.push(`$${i++} = ANY(p.tags)`);   params.push(tag); }
    if (featured === 'true')     { conditions.push(`p.is_featured = true`); }
    if (new_arrival === 'true')  { conditions.push(`p.is_new_arrival = true`); }

    const allowedSort  = ['created_at', 'price', 'name'];
    const allowedOrder = ['asc', 'desc'];
    const safeSort  = allowedSort.includes(sort)   ? sort  : 'created_at';
    const safeOrder = allowedOrder.includes(order) ? order : 'desc';

    const offset = (Math.max(1, Number(page)) - 1) * Math.min(100, Number(limit));
    const lim    = Math.min(100, Number(limit));

    const { rows } = await dbQuery(`
      SELECT
        p.*,
        COALESCE(r.avg_rating, 0)   AS avg_rating,
        COALESCE(r.review_count, 0) AS review_count,
        inv.quantity - inv.reserved AS available_qty
      FROM products p
      LEFT JOIN product_rating_summary r   ON r.product_id = p.id
      LEFT JOIN inventory inv              ON inv.product_id = p.id
      WHERE ${conditions.join(' AND ')}
      ORDER BY p.${safeSort} ${safeOrder}
      LIMIT $${i++} OFFSET $${i++}
    `, [...params, lim, offset]);

    const { rows: countRows } = await dbQuery(`
      SELECT COUNT(*) FROM products p
      WHERE ${conditions.join(' AND ')}
    `, params);

    const result = {
      data:  rows,
      meta:  {
        total: parseInt(countRows[0].count),
        page:  Number(page),
        limit: lim,
        pages: Math.ceil(countRows[0].count / lim),
      },
    };

    await redis.setex(cacheKey, CACHE_TTL, JSON.stringify(result)).catch(() => {});
    res.json(result);
  } catch (err) {
    next(err);
  }
});

// GET /api/v1/products/:id
router.get('/:id', async (req, res, next) => {
  try {
    const cacheKey = `products:${req.params.id}`;
    const cached = await redis.get(cacheKey).catch(() => null);
    if (cached) return res.json(JSON.parse(cached));

    const { rows } = await dbQuery(`
      SELECT
        p.*,
        COALESCE(r.avg_rating, 0)   AS avg_rating,
        COALESCE(r.review_count, 0) AS review_count,
        COALESCE(r.five_star, 0)    AS five_star,
        COALESCE(r.four_star, 0)    AS four_star,
        COALESCE(r.three_star, 0)   AS three_star,
        inv.quantity - inv.reserved AS available_qty,
        inv.quantity,
        inv.reserved
      FROM products p
      LEFT JOIN product_rating_summary r ON r.product_id = p.id
      LEFT JOIN inventory inv            ON inv.product_id = p.id
      WHERE p.id = $1 AND p.status = 'active'
    `, [req.params.id]);

    if (!rows[0]) return res.status(404).json({ error: 'Product not found' });

    // Fetch variants
    const { rows: variants } = await dbQuery(
      `SELECT * FROM product_variants WHERE product_id = $1 ORDER BY position`,
      [req.params.id]
    );

    // Fetch reviews (latest 10)
    const { rows: reviews } = await dbQuery(`
      SELECT r.*, c.given_name, c.family_name
      FROM reviews r
      JOIN customers c ON c.id = r.customer_id
      WHERE r.product_id = $1 AND r.status = 'approved'
      ORDER BY r.created_at DESC LIMIT 10
    `, [req.params.id]);

    const product = { ...rows[0], variants, reviews };
    await redis.setex(cacheKey, CACHE_TTL, JSON.stringify(product)).catch(() => {});
    res.json(product);
  } catch (err) {
    next(err);
  }
});

// POST /api/v1/products — admin only
router.post('/', authenticate, requireRole('admin'), async (req, res, next) => {
  try {
    const {
      sku, name, slug, description, short_desc, category,
      price, compare_at_price, images, tags, attributes,
      is_featured, is_new_arrival, status,
    } = req.body;

    const { rows } = await dbQuery(`
      INSERT INTO products
        (sku, name, slug, description, short_desc, category, price,
         compare_at_price, images, tags, attributes, is_featured, is_new_arrival, status)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
      RETURNING *
    `, [sku, name, slug, description, short_desc, category, price,
        compare_at_price, JSON.stringify(images || []), tags,
        JSON.stringify(attributes || {}), is_featured || false,
        is_new_arrival || false, status || 'draft']);

    // Seed inventory record
    await dbQuery(
      `INSERT INTO inventory (product_id, quantity) VALUES ($1, 0)`,
      [rows[0].id]
    );

    // Invalidate list cache
    const keys = await redis.keys('products:list:*').catch(() => []);
    if (keys.length) await redis.del(keys).catch(() => {});

    res.status(201).json(rows[0]);
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ error: 'SKU or slug already exists' });
    next(err);
  }
});

// PATCH /api/v1/products/:id — admin only
router.patch('/:id', authenticate, requireRole('admin'), async (req, res, next) => {
  try {
    const allowed = ['name','description','price','status','is_featured','is_new_arrival','images','tags','attributes'];
    const updates = [];
    const params  = [];
    let i = 1;

    for (const [key, val] of Object.entries(req.body)) {
      if (allowed.includes(key)) {
        updates.push(`${key} = $${i++}`);
        params.push(typeof val === 'object' ? JSON.stringify(val) : val);
      }
    }

    if (!updates.length) return res.status(400).json({ error: 'No valid fields to update' });

    params.push(req.params.id);
    const { rows } = await dbQuery(
      `UPDATE products SET ${updates.join(', ')}, updated_at = NOW() WHERE id = $${i} RETURNING *`,
      params
    );

    if (!rows[0]) return res.status(404).json({ error: 'Product not found' });

    // Bust cache
    await redis.del(`products:${req.params.id}`).catch(() => {});
    const keys = await redis.keys('products:list:*').catch(() => []);
    if (keys.length) await redis.del(keys).catch(() => {});

    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
