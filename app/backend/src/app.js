'use strict';

require('dotenv').config();
const path = require('path');

const express      = require('express');
const helmet       = require('helmet');
const cors         = require('cors');
const compression  = require('compression');
const rateLimit    = require('express-rate-limit');
const pinoHttp     = require('pino-http');
const logger       = require('./config/logger');

const app = express();

// ── Security headers (mirrors CloudFront response header policy) ──────────────
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:  ["'self'"],
      scriptSrc:   ["'self'"],
      styleSrc:    ["'self'", "'unsafe-inline'"],
      imgSrc:      ["'self'", "data:", "https:"],
      connectSrc:  ["'self'"],
    },
  },
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: true },
}));

// ── CORS ─────────────────────────────────────────────────────────────────────
const allowedOrigins = (process.env.CORS_ORIGINS || 'http://localhost:3000').split(',');
app.use(cors({
  origin: (origin, cb) => {
    if (!origin || allowedOrigins.includes(origin)) return cb(null, true);
    cb(new Error(`CORS: origin ${origin} not allowed`));
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
}));

// ── Body parsing & compression ────────────────────────────────────────────────
app.use(compression());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// ── HTTP request logging ──────────────────────────────────────────────────────
app.use(pinoHttp({ logger, autoLogging: { ignore: (req) => req.url === '/health' } }));

// ── Global rate limiting (mirrors WAF rate rule) ──────────────────────────────
app.use('/api/', rateLimit({
  windowMs:  60 * 1000,  // 1 minute
  max:       200,
  standardHeaders: true,
  legacyHeaders:   false,
  message: { error: 'Too many requests, please slow down.' },
}));

// ── Health check (used by ALB + ECS healthcheck) ──────────────────────────────
app.get('/health', async (req, res) => {
  const { pool }  = require('./config/db');
  const redis     = require('./config/redis');

  const checks = { api: 'ok', db: 'unknown', redis: 'unknown' };

  try {
    await pool.query('SELECT 1');
    checks.db = 'ok';
  } catch {
    checks.db = 'error';
  }

  try {
    await redis.ping();
    checks.redis = 'ok';
  } catch {
    checks.redis = 'error';
  }

  const healthy = Object.values(checks).every(v => v === 'ok');
  res.status(healthy ? 200 : 503).json({
    status:  healthy ? 'healthy' : 'degraded',
    checks,
    version: process.env.npm_package_version || '1.0.0',
    uptime:  Math.floor(process.uptime()),
  });
});

// ── API Routes ────────────────────────────────────────────────────────────────
app.use('/api/v1/auth',      require('./routes/auth'));
app.use('/api/v1/products',  require('./routes/products'));
app.use('/api/v1/cart',      require('./routes/cart'));
app.use('/api/v1/orders',    require('./routes/orders'));
app.use('/api/v1/customers', require('./routes/customers'));
app.use('/api/v1/documents', require('./routes/documents'));
app.use('/api/v1/search',    require('./routes/search'));
app.use('/api/v1/operations', require('./routes/operations'));

// Non-Docker local mode: serve frontend from Express to keep same-origin API calls.
const frontendDir = path.resolve(__dirname, '../../frontend');
app.use(express.static(frontendDir));
app.get('/src/operations.html', (req, res) => {
  res.sendFile(path.join(frontendDir, 'src/operations.html'));
});
app.get('/', (req, res) => {
  res.sendFile(path.join(frontendDir, 'index.html'));
});

// ── 404 ───────────────────────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Not found', path: req.path });
});

// ── Global error handler ──────────────────────────────────────────────────────
app.use((err, req, res, next) => {
  const status = err.status || err.statusCode || 500;
  if (status >= 500) {
    req.log.error({ err }, 'Unhandled server error');
  }
  res.status(status).json({
    error:   status >= 500 ? 'Internal server error' : err.message,
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack }),
  });
});

module.exports = app;
