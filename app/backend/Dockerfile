# ─── Base ─────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS base
WORKDIR /app
RUN apk add --no-cache curl

# ─── Dependencies ─────────────────────────────────────────────────────────────
FROM base AS deps
COPY package*.json ./
RUN npm ci

# ─── Development (hot-reload with nodemon) ────────────────────────────────────
FROM base AS development
COPY package*.json ./
RUN npm ci
COPY . .
EXPOSE 3001
CMD ["npm", "run", "dev"]

# ─── Production build ─────────────────────────────────────────────────────────
FROM base AS production
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY . .
# Non-root user (mirrors ECS task hardening)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3001/health || exit 1
CMD ["node", "src/server.js"]
