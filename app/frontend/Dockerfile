# ─── Base ─────────────────────────────────────────────────────────────────────
FROM node:20-alpine AS base
WORKDIR /app
RUN apk add --no-cache curl

# ─── Development (serve static HTML with live-reload via browser-sync) ────────
FROM base AS development
RUN npm install -g browser-sync
COPY . .
EXPOSE 3000
CMD ["browser-sync", "start", "--server", "--files", "**/*.html,**/*.css,**/*.js", "--port", "3000", "--no-open"]

# ─── Production (nginx static server) ────────────────────────────────────────
FROM nginx:1.25-alpine AS production
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s \
  CMD curl -f http://localhost:3000/ || exit 1
