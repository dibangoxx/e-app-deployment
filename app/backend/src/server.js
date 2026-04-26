'use strict';

const app     = require('./app');
const logger  = require('./config/logger');

const PORT = process.env.PORT || 3001;

const server = app.listen(PORT, () => {
  logger.info({ port: PORT, env: process.env.NODE_ENV }, 'FlashInfo API started');
});

// Graceful shutdown — mirrors ECS SIGTERM handling
const shutdown = (signal) => {
  logger.info({ signal }, 'Shutdown signal received');
  server.close(() => {
    logger.info('HTTP server closed');
    // Close DB pool, Redis, etc.
    require('./config/db').pool.end(() => {
      logger.info('DB pool closed');
      process.exit(0);
    });
  });
  // Force exit after 10s if graceful shutdown stalls
  setTimeout(() => process.exit(1), 10_000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

process.on('unhandledRejection', (reason) => {
  logger.error({ reason }, 'Unhandled promise rejection');
  process.exit(1);
});
