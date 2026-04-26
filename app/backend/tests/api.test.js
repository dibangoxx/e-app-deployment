'use strict';

/**
 * FlashInfo API — Integration Tests
 * Run: npm test (inside the api container or locally with services up)
 */

const request = require('supertest');
const app     = require('../src/app');

// ── Helpers ───────────────────────────────────────────────────────────────────
let authToken;
let testProductId;

const testUser = {
  email:       `test-${Date.now()}@flashinfo.local`,
  password:    'TestPass123!',
  given_name:  'Test',
  family_name: 'User',
};

// ── Health ────────────────────────────────────────────────────────────────────
describe('GET /health', () => {
  it('returns 200 with status fields', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('status');
    expect(res.body).toHaveProperty('checks');
    expect(res.body.checks).toHaveProperty('api', 'ok');
  });
});

// ── Auth ──────────────────────────────────────────────────────────────────────
describe('POST /api/v1/auth/register', () => {
  it('registers a new customer', async () => {
    const res = await request(app)
      .post('/api/v1/auth/register')
      .send(testUser);

    expect(res.status).toBe(201);
    expect(res.body).toHaveProperty('token');
    expect(res.body.customer).toHaveProperty('email', testUser.email);
    authToken = res.body.token;
  });

  it('rejects duplicate email', async () => {
    const res = await request(app)
      .post('/api/v1/auth/register')
      .send(testUser);
    expect(res.status).toBe(409);
  });

  it('rejects short password', async () => {
    const res = await request(app)
      .post('/api/v1/auth/register')
      .send({ ...testUser, email: 'other@test.com', password: 'short' });
    expect(res.status).toBe(400);
  });
});

describe('POST /api/v1/auth/login', () => {
  it('logs in with correct credentials', async () => {
    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: testUser.email, password: testUser.password });

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('token');
    authToken = res.body.token;
  });

  it('rejects wrong password', async () => {
    const res = await request(app)
      .post('/api/v1/auth/login')
      .send({ email: testUser.email, password: 'wrongpassword' });
    expect(res.status).toBe(401);
  });
});

describe('GET /api/v1/auth/me', () => {
  it('returns current customer when authenticated', async () => {
    const res = await request(app)
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${authToken}`);

    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('email', testUser.email);
  });

  it('returns 401 without token', async () => {
    const res = await request(app).get('/api/v1/auth/me');
    expect(res.status).toBe(401);
  });
});

// ── Products ──────────────────────────────────────────────────────────────────
describe('GET /api/v1/products', () => {
  it('returns paginated product list', async () => {
    const res = await request(app).get('/api/v1/products');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('data');
    expect(res.body).toHaveProperty('meta');
    expect(Array.isArray(res.body.data)).toBe(true);

    if (res.body.data.length > 0) {
      testProductId = res.body.data[0].id;
    }
  });

  it('filters by category', async () => {
    const res = await request(app)
      .get('/api/v1/products?category=living_room');
    expect(res.status).toBe(200);
    res.body.data.forEach(p => {
      expect(p.category).toBe('living_room');
    });
  });

  it('filters by price range', async () => {
    const res = await request(app)
      .get('/api/v1/products?min_price=50&max_price=200');
    expect(res.status).toBe(200);
    res.body.data.forEach(p => {
      expect(Number(p.price)).toBeGreaterThanOrEqual(50);
      expect(Number(p.price)).toBeLessThanOrEqual(200);
    });
  });

  it('respects pagination limit', async () => {
    const res = await request(app)
      .get('/api/v1/products?limit=3&page=1');
    expect(res.status).toBe(200);
    expect(res.body.data.length).toBeLessThanOrEqual(3);
  });
});

describe('GET /api/v1/products/:id', () => {
  it('returns a single product with variants and reviews', async () => {
    if (!testProductId) return;
    const res = await request(app)
      .get(`/api/v1/products/${testProductId}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('id', testProductId);
    expect(res.body).toHaveProperty('variants');
    expect(res.body).toHaveProperty('reviews');
  });

  it('returns 404 for unknown product', async () => {
    const res = await request(app)
      .get('/api/v1/products/00000000-0000-0000-0000-000000000000');
    expect(res.status).toBe(404);
  });
});

// ── Cart ─────────────────────────────────────────────────────────────────────
describe('Cart endpoints', () => {
  const sessionId = `test-session-${Date.now()}`;

  it('returns empty cart for new session', async () => {
    const res = await request(app)
      .get(`/api/v1/cart?session_id=${sessionId}`);
    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('adds an item to cart', async () => {
    if (!testProductId) return;
    const res = await request(app)
      .post('/api/v1/cart/add')
      .send({ session_id: sessionId, product_id: testProductId, quantity: 2 });

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0].quantity).toBe(2);
    expect(res.body.subtotal).toBeGreaterThan(0);
  });

  it('updates item quantity', async () => {
    if (!testProductId) return;
    const res = await request(app)
      .patch('/api/v1/cart/update')
      .send({ session_id: sessionId, product_id: testProductId, quantity: 1 });

    expect(res.status).toBe(200);
    expect(res.body.items[0].quantity).toBe(1);
  });

  it('clears the cart', async () => {
    const res = await request(app)
      .delete(`/api/v1/cart/clear?session_id=${sessionId}`);
    expect(res.status).toBe(200);
  });
});

// ── Search ────────────────────────────────────────────────────────────────────
describe('GET /api/v1/search', () => {
  it('returns results for a valid query', async () => {
    const res = await request(app)
      .get('/api/v1/search?q=chair');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('data');
    expect(Array.isArray(res.body.data)).toBe(true);
  });

  it('returns 400 without query param', async () => {
    const res = await request(app).get('/api/v1/search');
    expect(res.status).toBe(400);
  });
});

// ── 404 ───────────────────────────────────────────────────────────────────────
describe('Unknown routes', () => {
  it('returns 404 for unknown paths', async () => {
    const res = await request(app).get('/api/v1/nonexistent');
    expect(res.status).toBe(404);
  });
});
