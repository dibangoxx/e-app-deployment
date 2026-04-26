'use strict';
const express = require('express');
const { query: db } = require('../config/db');
const { s3 } = require('../config/aws');
const { PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { authenticate } = require('../middleware/auth');
const { v4: uuid } = require('uuid');
const router = express.Router();

const BUCKET = process.env.DOCUMENTS_BUCKET || 'flashinfo-documents-local';

router.post('/upload-url', authenticate, async (req, res, next) => {
  try {
    const { filename, content_type } = req.body;
    const key = `customers/${req.user.sub}/${uuid()}-${filename}`;
    const cmd = new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: content_type });
    const url = await getSignedUrl(s3, cmd, { expiresIn: 3600 });
    res.json({ upload_url: url, key });
  } catch (err) { next(err); }
});

router.get('/:id/download', authenticate, async (req, res, next) => {
  try {
    const { rows } = await db(`SELECT * FROM documents WHERE id=$1 AND customer_id=$2`, [req.params.id, req.user.sub]);
    if (!rows[0]) return res.status(404).json({ error: 'Document not found' });
    const cmd = new GetObjectCommand({ Bucket: rows[0].s3_bucket, Key: rows[0].s3_key });
    const url = await getSignedUrl(s3, cmd, { expiresIn: 900 });
    res.json({ download_url: url });
  } catch (err) { next(err); }
});

module.exports = router;
