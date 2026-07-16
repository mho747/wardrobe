# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY index.html vite.config.mjs ./
COPY public ./public
COPY src ./src
COPY scripts ./scripts
RUN npm run build

FROM node:22-bookworm-slim AS runtime

ARG VCS_REF=unknown
WORKDIR /app
ENV NODE_ENV=production
LABEL org.opencontainers.image.revision=$VCS_REF

COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/vite.config.mjs ./vite.config.mjs
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/scripts ./scripts
COPY --from=build --chown=node:node /app/dist ./dist

USER node
EXPOSE 4173

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD ["node", "-e", "const http=require('node:http');const request=http.get('http://127.0.0.1:4173/api/import/config',(response)=>{response.resume();process.exit(response.statusCode===200?0:1)});request.setTimeout(4000,()=>request.destroy(new Error('timeout')));request.on('error',()=>process.exit(1));"]

CMD ["npm", "run", "preview", "--", "--host", "0.0.0.0", "--port", "4173", "--strictPort"]
