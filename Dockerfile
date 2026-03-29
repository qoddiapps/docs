# Use Node.js official image
FROM node:18-alpine

# Set working directory
WORKDIR /app

# Install Mintlify CLI globally
RUN npm install -g @mintlify/cli@latest

# Copy all documentation files
COPY . .

# Create package.json for dependencies
RUN echo '{"name": "mintlify-docs", "version": "1.0.0", "scripts": {"start": "mintlify dev --host 0.0.0.0 --port 3000"}}' > package.json

# Expose port 3000
EXPOSE 3000

# Start the Mintlify development server
CMD ["npm", "start"]