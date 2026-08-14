FROM node:24-alpine AS build

WORKDIR /repo
RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/core/package.json packages/core/package.json
COPY apps/api/package.json apps/api/package.json
RUN pnpm install --frozen-lockfile

COPY packages/core packages/core
COPY apps/api apps/api
RUN pnpm --filter @robur/core build && pnpm --filter @robur/api build

FROM node:24-alpine AS runtime

ENV NODE_ENV=production
WORKDIR /repo
RUN corepack enable

COPY --from=build /repo/package.json /repo/pnpm-lock.yaml /repo/pnpm-workspace.yaml ./
COPY --from=build /repo/node_modules node_modules
COPY --from=build /repo/packages/core packages/core
COPY --from=build /repo/apps/api apps/api

EXPOSE 8080
CMD ["node", "apps/api/dist/index.js"]
