FROM --platform=linux/amd64 node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY public ./public
COPY server.js .

ENV PORT=3000
ENV NODE_ENV=production

EXPOSE 3000

CMD ["node", "server.js"]
