// config/logger.js
'use strict';
const pino = require('pino');
module.exports = pino({
  level: process.env.LOG_LEVEL || 'info',
  ...(process.env.NODE_ENV === 'development' && {
    transport: { target: 'pino-pretty', options: { colorize: true, ignore: 'pid,hostname' } },
  }),
});
