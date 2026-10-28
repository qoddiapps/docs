# Mintlify documentation site (AppJet docs)
FROM node:20-alpine

WORKDIR /app

# Pin the Mintlify CLI to a version verified to work with this repo.
# (`@latest` was the source of an earlier breakage.)
RUN npm install -g @mintlify/cli@4.0.1762

# Copy the documentation source (docs.json, *.mdx, images, ...)
COPY . .

ENV PORT=3000
EXPOSE 3000

# --host binds the preview to all interfaces (0.0.0.0) so the platform proxy
# can reach it; without it the server listens on localhost only and the site
# returns a 502/520. The CLI has no --port flag: it always uses PORT (3000).
CMD ["mintlify", "dev", "--host", "--no-open"]
