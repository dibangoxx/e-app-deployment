'use strict';
const express = require('express');
const { query: db } = require('../config/db');
const router  = express.Router();

router.get('/', async (req, res, next) => {
  try {
    const { q, category, min_price, max_price, page=1, limit=20 } = req.query;
    if (!q) return res.status(400).json({ error: 'q (query) is required' });

    try {
      const osHost = process.env.OPENSEARCH_HOST || 'http://localhost:9200';
      const body = {
        from: (Number(page)-1)*Number(limit), size: Number(limit),
        query: { bool: {
          must: [{ multi_match: { query: q, fields: ['name^3','description','tags^2'] } }],
          filter: [
            { term: { status: 'active' } },
            ...(category  ? [{ term: { category } }] : []),
            ...(min_price ? [{ range: { price: { gte: Number(min_price) } } }] : []),
            ...(max_price ? [{ range: { price: { lte: Number(max_price) } } }] : []),
          ],
        }},
      };
      const r = await fetch(`${osHost}/flashinfo-products/_search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      if (r.ok) {
        const data = await r.json();
        return res.json({ data: data.hits.hits.map(h => h._source), total: data.hits.total.value, source: 'opensearch' });
      }
    } catch { /* fallback */ }

    const clauses = ['p.status = $1'];
    const params  = ['active'];
    let i = 2;
    if (category)  { clauses.push(`p.category = $${i++}`);                params.push(category); }
    if (min_price) { clauses.push(`p.price >= $${i++}`);                  params.push(Number(min_price)); }
    if (max_price) { clauses.push(`p.price <= $${i++}`);                  params.push(Number(max_price)); }
    clauses.push(`to_tsvector('english', p.name||' '||COALESCE(p.description,'')) @@ plainto_tsquery($${i})`);
    params.push(q);

    const { rows } = await db(`
      SELECT p.*, ts_rank(to_tsvector('english', p.name||' '||COALESCE(p.description,'')), plainto_tsquery($${i})) AS rank
      FROM products p WHERE ${clauses.join(' AND ')} ORDER BY rank DESC LIMIT $${i+1} OFFSET $${i+2}
    `, [...params, Number(limit), (Number(page)-1)*Number(limit)]);

    res.json({ data: rows, source: 'postgres' });
  } catch (err) { next(err); }
});

module.exports = router;
