FROM node:22-alpine
WORKDIR /app/keeper
COPY keeper/package.json ./
RUN npm install --omit=dev
COPY keeper/src ./src
COPY deployments /app/deployments
ENV DEPLOYMENT=/app/deployments/1.json
USER node
CMD ["node", "src/index.mjs"]
