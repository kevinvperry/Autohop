FROM node:22-alpine
WORKDIR /service
COPY --chown=node:node server.mjs package.json ./
USER node
EXPOSE 8080
CMD ["node", "server.mjs"]
