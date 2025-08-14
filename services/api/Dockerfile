# syntax=docker/dockerfile:1.6
ARG NODE_VERSION=20
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /app
COPY . .
RUN npm ci && npm run build

FROM node:${NODE_VERSION}-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/dist ./dist
COPY --from=deps /app/node_modules ./node_modules
EXPOSE 3000
CMD ["node","dist/main.js"]
