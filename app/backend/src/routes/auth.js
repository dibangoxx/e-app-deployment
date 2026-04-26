// ─── routes/auth.js ───────────────────────────────────────────────────────────
'use strict';

const express  = require('express');
const bcrypt   = require('bcryptjs');
const jwt      = require('jsonwebtoken');
const { query: db } = require('../config/db');
const redis    = require('../config/redis');
const logger   = require('../config/logger');
const { authenticate } = require('../middleware/auth');

const router = express.Router();
const JWT_SECRET  = process.env.JWT_SECRET  || 'flashinfo-local-dev-secret';
const JWT_EXPIRES = process.env.JWT_EXPIRES || '1h';

function issueToken(customer) {
  return jwt.sign(
    { sub: customer.id, email: customer.email, role: customer.role, name: customer.given_name },
    JWT_SECRET,
    { expiresIn: JWT_EXPIRES }
  );
}

// POST /api/v1/auth/register
router.post('/register', async (req, res, next) => {
  try {
    const { email, password, given_name, family_name, accepts_marketing } = req.body;
    if (!email || !password || !given_name || !family_name) {
      return res.status(400).json({ error: 'email, password, given_name and family_name are required' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    const hash = await bcrypt.hash(password, 12);
    const cognitoSub = `local-${Date.now()}-${Math.random().toString(36).slice(2)}`;

    const { rows } = await db(`
      INSERT INTO customers (cognito_sub, email, given_name, family_name, accepts_marketing)
      VALUES ($1, $2, $3, $4, $5)
      RETURNING id, email, given_name, family_name, role, created_at
    `, [cognitoSub, email.toLowerCase(), given_name, family_name, accepts_marketing || false]);

    // Store hashed password in a local dev table (not used in prod — Cognito handles auth)
    await db(
      `CREATE TABLE IF NOT EXISTS local_credentials (customer_id UUID PRIMARY KEY, hash TEXT);
       INSERT INTO local_credentials VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [rows[0].id, hash]
    );

    const token = issueToken(rows[0]);
    logger.info({ customerId: rows[0].id }, 'Customer registered');
    res.status(201).json({ token, customer: rows[0] });
  } catch (err) {
    if (err.code === '23505') return res.status(409).json({ error: 'Email already registered' });
    next(err);
  }
});

// POST /api/v1/auth/login
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'email and password required' });

    const { rows } = await db(`
      SELECT c.*, lc.hash
      FROM customers c
      LEFT JOIN local_credentials lc ON lc.customer_id = c.id
      WHERE c.email = $1
    `, [email.toLowerCase()]);

    if (!rows[0] || !rows[0].hash) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const valid = await bcrypt.compare(password, rows[0].hash);
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' });

    await db(`UPDATE customers SET last_login_at = NOW() WHERE id = $1`, [rows[0].id]);

    const { hash: _, ...customer } = rows[0];
    const token = issueToken(customer);
    logger.info({ customerId: customer.id }, 'Customer logged in');
    res.json({ token, customer });
  } catch (err) {
    next(err);
  }
});

// GET /api/v1/auth/me
router.get('/me', authenticate, async (req, res, next) => {
  try {
    const { rows } = await db(
      `SELECT id, email, given_name, family_name, role, total_spent, orders_count, created_at
       FROM customers WHERE id = $1`,
      [req.user.sub]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Customer not found' });
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});

module.exports = router;
