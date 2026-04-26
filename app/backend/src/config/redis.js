'use strict';

const Redis  = require('ioredis');
const logger = require('./logger');

const redis = new Redis({
  host:     process.env.REDIS_HOST     || 'localhost',
  port:     parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD || 'flashinfo_redis_local',
  retryStrategy: (times) => Math.min(times * 100, 3000),
  maxRetriesPerRequest: 3,
  lazyConnect: true,
});

redis.on('error',   (err) => logger.error({ err }, 'Redis error'));
redis.on('connect', ()    => logger.info('Redis connected'));

module.exports = redis;
