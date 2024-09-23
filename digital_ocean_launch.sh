#!/bin/bash

# Set up logging
LOGFILE="/var/log/momcon_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "Starting setup script at $(date)"

# Update package lists
sudo apt update -y

# Upgrade packages non-interactively, automatically handle prompts
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install packages. curl is needed to fetch the public IP address
sudo apt install -y python3-pip python3-venv nginx git curl

# Restart and enable Nginx to run on startup
sudo systemctl restart nginx
sudo systemctl enable nginx

# Variables
APP_DIR="/var/www/momento_contento"
REPO_URL="https://github.com/followcrom/momento_contento.git"
GUNICORN_PORT="5000"

# Create application directory if it doesn't exist
if [ ! -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR"
fi

# Clone the Git repository
if [ -d "$APP_DIR/.git" ]; then
    echo "Repository already exists, pulling latest changes..."
    cd "$APP_DIR"
    git pull
else
    echo "Cloning repository..."
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR"
fi

cd "$APP_DIR/app"

# Set up Python virtual environment
python3 -m venv momcon_venv
source momcon_venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# To detect the public IP address of a VM on Digital Ocean
PUBLIC_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)

# To detect the public IP address of the VM using the AWS EC2 metadata service
# PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Create Nginx configuration for the app
# Be sure to use Escaped Dollar Signs ($host, $remote_addr, etc.) to prevent shell interpretation errors
sudo bash -c "cat > /etc/nginx/sites-available/momcon" <<EOF
server {
    listen 80;
    server_name $PUBLIC_IP;

    # Flask app under /momcon. Be sure to adjust Flask for subpath
    location /momcon/ {
        proxy_pass http://localhost:5000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias /var/www/momento_contento/app/static/;
    }
}
EOF

# Enable the Nginx site
sudo ln -sf /etc/nginx/sites-available/momcon /etc/nginx/sites-enabled

# Test Nginx configuration for syntax errors
if sudo nginx -t; then
    echo "Nginx configuration syntax is okay."
    sudo systemctl restart nginx
    echo "Nginx restarted successfully."
else
    echo "Error in Nginx configuration."
fi

# Create Systemd service for Gunicorn
# Use cat (or tee) to write the content directly. Using nano requires user interaction
sudo bash -c "cat > /etc/systemd/system/momcon.service" <<EOF
[Unit]
Description=Gunicorn instance to serve Momento Contento app
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=$APP_DIR/app
Environment="PATH=$APP_DIR/app/momcon_venv/bin"
ExecStart=$APP_DIR/app/momcon_venv/bin/gunicorn --workers 3 --bind 0.0.0.0:$GUNICORN_PORT application:application

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the Gunicorn service
sudo systemctl daemon-reload
sudo systemctl enable momcon
sudo systemctl start momcon
sudo systemctl restart momcon

echo "Setup complete. Your application should be accessible at http://$PUBLIC_IP/momcon/"