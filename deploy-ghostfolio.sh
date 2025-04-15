#!/bin/bash

# Install necessary packages
sudo apt-get update -y
sudo apt-get install nginx certbot python3-certbot-nginx ca-certificates curl git -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Issue Let's Encrypt Certificate
sudo certbot --nginx -d ghostfolio.atanov.pp.ua --email atanov.v@gmail.com --agree-tos --non-interactive

# Configure Nginx as reverse proxy for Ghostfolio app
sudo tee /etc/nginx/sites-available/ghostfolio <<EOF
server {
    listen 80;
    server_name ghostfolio.atanov.pp.ua;

    # Redirect all HTTP traffic to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ghostfolio.atanov.pp.ua;

    ssl_certificate     /etc/letsencrypt/live/ghostfolio.atanov.pp.ua/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ghostfolio.atanov.pp.ua/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://localhost:3333;  # Forward to Ghostfolio running on port 3333
        proxy_http_version 1.1;
        
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;  # Add the remote IP address
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;  # Add the forwarded IP address
        proxy_set_header X-Forwarded-Proto \$scheme;  # Add the protocol (http/https)
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Download, configure and run containers with Ghostfolio app, DB and Redis
git clone https://github.com/ghostfolio/ghostfolio.git

cd ghostfolio/
touch .env

tee .env <<EOF
COMPOSE_PROJECT_NAME=ghostfolio
# CACHE"
REDIS_HOST=gf-redis
REDIS_PORT=6379
REDIS_PASSWORD=Secret1234
# POSTGRES
POSTGRES_DB=ghostfolio-db
POSTGRES_USER=user
POSTGRES_PASSWORD=Secret1234
# VARIOUS
ACCESS_TOKEN_SALT=bvl98arpI1MT6iF8r+FiiCeWIGiGoA1eT9TE9Q3lCxE=
DATABASE_URL=postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@gf-postgres:5432/\${POSTGRES_DB}?connect_timeout=300&sslmode=prefer
JWT_SECRET_KEY=BaTvHTkd1LHhFehV0oHtViAIO0W6BjBspNKP7TbLVhxcPFViGKNkCW0r3ZRtSEVu5zjt3i+LNEJqhMHPcDGZDg==
EOF

sudo docker compose -f docker/docker-compose.yml up -d

# Enable Nginx configuration and restart Nginx
sudo ln -s /etc/nginx/sites-available/ghostfolio /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
