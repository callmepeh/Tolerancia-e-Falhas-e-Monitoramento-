# ============================================================
# Imagem da aplicação meteo-api (Atividade 4 - SD)
# Multi-stage: build das dependências + runtime mínimo
# ============================================================
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY --from=deps /app/node_modules ./node_modules
COPY server.js package.json ./
EXPOSE 8080
# roda como usuário não-root (boa prática)
USER node
CMD ["node", "server.js"]
