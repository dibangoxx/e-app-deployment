'use strict';

const { Pool } = require('pg');
const logger   = require('./logger');

const pool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME     || 'flashinfo',
  user:     process.env.DB_USER     || 'flashinfo_admin',
  password: process.env.DB_PASSWORD || 'flashinfo_local_password',
  max:      20,     // max pool size (mirrors Aurora max_connections)
  idleTimeoutMillis:    30_000,
  connectionTimeoutMillis: 5_000,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: true } : false,
});

pool.on('error', (err) => {
  logger.error({ err }, 'Unexpected DB pool error');
});

pool.on('connect', () => {
  logger.debug('New DB connection established');
});

// Retry helper — useful for startup when postgres is still initialising
async function query(text, params, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try {
      return await pool.query(text, params);
    } catch (err) {
      if (i === retries - 1) throw err;
      logger.warn({ err, attempt: i + 1 }, 'DB query failed, retrying...');
      await new Promise(r => setTimeout(r, 500 * (i + 1)));
    }
  }
}

// Transaction helper
async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, query, withTransaction };
