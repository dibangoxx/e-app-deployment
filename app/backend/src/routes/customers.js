'use strict';
const express  = require('express');
const { query: db } = require('../config/db');
const { authenticate, requireRole } = require('../middleware/auth');
const router   = express.Router();

router.get('/addresses', authenticate, async (req, res, next) => {
  try {
    const { rows } = await db(`SELECT * FROM customer_addresses WHERE customer_id=$1 ORDER BY is_default DESC`, [req.user.sub]);
    res.json(rows);
  } catch (err) { next(err); }
});

router.post('/addresses', authenticate, async (req, res, next) => {
  try {
    const { first_name, last_name, address_line1, address_line2, city, state_province, postal_code, country_code, is_default } = req.body;
    if (is_default) await db(`UPDATE customer_addresses SET is_default=false WHERE customer_id=$1`, [req.user.sub]);
    const { rows } = await db(`
      INSERT INTO customer_addresses (customer_id,first_name,last_name,address_line1,address_line2,city,state_province,postal_code,country_code,is_default)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *
    `, [req.user.sub,first_name,last_name,address_line1,address_line2,city,state_province,postal_code,country_code||'US',is_default||false]);
    res.status(201).json(rows[0]);
  } catch (err) { next(err); }
});

router.get('/', authenticate, requireRole('admin'), async (req, res, next) => {
  try {
    const { page=1, limit=20, search } = req.query;
    const offset = (Math.max(1,Number(page))-1)*Number(limit);
    let sql = `SELECT id,email,given_name,family_name,role,total_spent,orders_count,created_at FROM customers`;
    const params = [];
    if (search) { sql += ` WHERE email ILIKE $1 OR given_name ILIKE $1 OR family_name ILIKE $1`; params.push(`%${search}%`); }
    sql += ` ORDER BY created_at DESC LIMIT $${params.length+1} OFFSET $${params.length+2}`;
    const { rows } = await db(sql, [...params, Number(limit), offset]);
    res.json({ data: rows });
  } catch (err) { next(err); }
});

module.exports = router;
