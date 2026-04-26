'use strict';
const express = require('express');
const redis   = require('../config/redis');
const { query: db } = require('../config/db');
const router  = express.Router();

const cartKey = (id) => `cart:${id}`;
const TTL = 60 * 60 * 24 * 7;

router.get('/', async (req, res, next) => {
  try {
    const id = req.query.session_id || req.user?.sub;
    if (!id) return res.status(400).json({ error: 'session_id required' });
    const raw = await redis.get(cartKey(id));
    const cart = raw ? JSON.parse(raw) : { items: [], session_id: id };
    res.json(cart);
  } catch (err) { next(err); }
});

router.post('/add', async (req, res, next) => {
  try {
    const { session_id, product_id, quantity = 1, variant_id } = req.body;
    const id = session_id || req.user?.sub;
    if (!id || !product_id) return res.status(400).json({ error: 'session_id and product_id required' });
    const { rows } = await db(`SELECT id, name, price, images FROM products WHERE id=$1 AND status='active'`, [product_id]);
    if (!rows[0]) return res.status(404).json({ error: 'Product not found' });
    const raw  = await redis.get(cartKey(id));
    const cart = raw ? JSON.parse(raw) : { items: [], session_id: id };
    const existing = cart.items.find(i => i.product_id === product_id && i.variant_id === variant_id);
    if (existing) { existing.quantity += Number(quantity); }
    else { cart.items.push({ product_id, variant_id: variant_id || null, quantity: Number(quantity), name: rows[0].name, price: parseFloat(rows[0].price), image: rows[0].images?.[0]?.url || null }); }
    cart.subtotal = cart.items.reduce((s, i) => s + i.price * i.quantity, 0);
    await redis.setex(cartKey(id), TTL, JSON.stringify(cart));
    res.json(cart);
  } catch (err) { next(err); }
});

router.patch('/update', async (req, res, next) => {
  try {
    const { session_id, product_id, quantity, variant_id } = req.body;
    const id = session_id || req.user?.sub;
    const raw = await redis.get(cartKey(id));
    if (!raw) return res.status(404).json({ error: 'Cart not found' });
    const cart = JSON.parse(raw);
    const idx  = cart.items.findIndex(i => i.product_id === product_id && i.variant_id === variant_id);
    if (idx === -1) return res.status(404).json({ error: 'Item not in cart' });
    if (quantity <= 0) { cart.items.splice(idx, 1); } else { cart.items[idx].quantity = Number(quantity); }
    cart.subtotal = cart.items.reduce((s, i) => s + i.price * i.quantity, 0);
    await redis.setex(cartKey(id), TTL, JSON.stringify(cart));
    res.json(cart);
  } catch (err) { next(err); }
});

router.delete('/clear', async (req, res, next) => {
  try {
    const id = req.query.session_id || req.user?.sub;
    await redis.del(cartKey(id));
    res.json({ message: 'Cart cleared' });
  } catch (err) { next(err); }
});

module.exports = router;
