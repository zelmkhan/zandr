# zandr's API: Node runs the TypeScript as it is (type stripping), and it has no dependencies, so
# the image holds only the server code and this entry point.
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY src/server ./src/server
COPY api/main.ts api/rpc.ts api/logos.ts api/keys.ts api/exchangeTokens.ts api/jupiter.ts ./api/
USER node
CMD ["node", "--disable-warning=ExperimentalWarning", "api/main.ts"]
