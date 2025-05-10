#!/bin/bash

# Install necessary packages
sudo apt-get update -y
sudo apt-get install nginx certbot python3-certbot-nginx ca-certificates curl git awscli -y
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
# CACHE
#REDIS_HOST=gf-redis
REDIS_HOST=ghostfolio-redis.gdzzpx.0001.use1.cache.amazonaws.com
REDIS_PORT=6379
#REDIS_PASSWORD=Secret1234
REDIS_PASSWORD=null
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


#############################################################################################################
#### Write a custom watcher script that runs docker compose up -d whenever the Compose file is modified. ####
#############################################################################################################

# Install inotify-tools
sudo apt-get install inotify-tools -y

# Create watcher script
tee /home/ubuntu/ghostfolio/watch-compose.sh <<EOF
#!/bin/bash
COMPOSE_FILE="/home/ubuntu/ghostfolio/docker/docker-compose.yml"
echo "Watching $COMPOSE_FILE for changes..."
while inotifywait -e modify "$COMPOSE_FILE"; do
  echo "Change detected, restarting containers..."
  docker compose -f "$COMPOSE_FILE" up -d
done
EOF

chmod +x /home/ubuntu/ghostfolio/watch-compose.sh

# Create systemd service
sudo tee /etc/systemd/system/compose-watcher.service > /dev/null <<EOF
[Unit]
Description=Watch docker-compose.yml and reload containers on change
After=network.target docker.service

[Service]
ExecStart=/home/ubuntu/ghostfolio/watch-compose.sh
WorkingDirectory=/home/ubuntu/ghostfolio
User=ubuntu
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable compose-watcher
sudo systemctl start compose-watcher

#######################################################################################
### Create a script to back up the database from the local host and upload it to S3 ###
#######################################################################################

tee /home/ubuntu/ghostfolio/backup_db.sh <<EOF
#!/bin/bash

# Filename with timestamp
TIMESTAMP=\$(date +\%F_\%H-\%M)
FILENAME="db_backup_\$TIMESTAMP.sql"
# Dump the DB
sudo docker exec gf-postgres pg_dump -U user ghostfolio-db > /tmp/\$FILENAME
# Upload to S3
aws s3 cp /tmp/\$FILENAME s3://ghostfolio-db-backup/\$FILENAME
# Clean up
rm /tmp/\$FILENAME
EOF

chmod +x /home/ubuntu/ghostfolio/backup_db.sh

/home/ubuntu/ghostfolio/backup_db.sh

sudo crontab -u ubuntu -l 2>/dev/null | grep -Fq "/home/ubuntu/ghostfolio/backup_db.sh" || \
( sudo crontab -u ubuntu -l 2>/dev/null; echo "0 3 * * * /home/ubuntu/ghostfolio/backup_db.sh" ) | sudo crontab -u ubuntu -
