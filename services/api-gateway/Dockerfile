FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY src/ ./src/

USER appuser

ENV NODE_ENV=production

EXPOSE 3000

CMD ["node", "-r", "./src/tracing.js", "src/index.js"]
