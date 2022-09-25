#!/bin/bash
# +----------------------------------------+
# | Default Conguration Variables
# +----------------------------------------+
DEFAULT_SSH_PORT=222
DEFAULT_TIMEZONE=America/Toronto
DEFAULT_FQDN=YOUR_FQDN
DEFAULT_HOST=YOU_HOSTNAME
DEFAULT_DOCKER_FOLDER=/home/docker
DEFAULT_USERNAME=YOUR_USERNAME

# +----------------------------------------+
# | DO NOT EDIT BELOW
# | UNLESS YOU KNOW WHAT YOU ARE DOING
# +----------------------------------------+
echo "============================================="
echo "=== Running Quick VM StackScript by SmEdD ==="
echo "============================================="

# +----------------------------------------+
# | Confirm Defaults
# +----------------------------------------+
read -p "SSH Port [$DEFAULT_SSH_PORT]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}

read -p "Timezone [$DEFAULT_TIMEZONE]: " TIMEZONE
TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}

read -p "FQDN [$DEFAULT_FQDN]: " FQDN
FQDN=${FQDN:-$DEFAULT_FQDN}

read -p "Host [$DEFAULT_HOST]: " HOST
HOST=${HOST:-$DEFAULT_HOST}

read -p "Docker Folder [$DEFAULT_DOCKER_FOLDER]: " DOCKER_FOLDER
DOCKER_FOLDER=${DOCKER_FOLDER:-$DEFAULT_DOCKER_FOLDER}

read -p "Secure Username [$DEFAULT_USERNAME]: " USERNAME
USERNAME=${USERNAME:-$DEFAULT_USERNAME}

# Minimum password requirements for the trusted user
while ! ([ "${#PASSWORD}" -ge 16 ] \
   && [[ "$PASSWORD" =~ [[:lower:]] ]] \
   && [[ "$PASSWORD" =~ [[:upper:]] ]] \
   && [[ "$PASSWORD" =~ [[:digit:]] ]])
do
  if [ "$password_entered" == 1 ]; then
    echo "Password must be a minimum of 16 characters including atleast one lowercase letter, uppercase letter, and a digit"
  fi
  password_entered=1
  read -s -p "Password: " PASSWORD
  echo
done

# Check for RSA signature AAAAB3NzaC1yc2EA
while ! [[ "$SSHKEY" =~ (AAAAB3NzaC1yc2EA) ]]
do
  if [ "$pubkey_entered" == 1 ]; then
    echo "Invalid public key entered, please try again."
  fi
  pubkey_entered=1
  read -s -p "SSH Public Key: " SSHKEY
  echo
done

# +----------------------------------------+
# | Setup Key Server Components
# +----------------------------------------+
# Harden SSH Access
sed -i -e "s/#Port 22/Port $SSH_PORT/g" /etc/ssh/sshd_config
sed -i -e 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
sed -i -e 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
sed -i -e '$aAddressFamily inet' /etc/ssh/sshd_config
systemctl restart sshd

# Ignore root password lock and secure user setup if username is blank or root
if [ "$USERNAME" != "" ] && [ "$USERNAME" != "root" ]; then
  # Disable root password
  passwd --lock root

  # ensure sudo is installed and configure secure user
  apt-get install sudo -y
  adduser $USERNAME --disabled-password --gecos ""
  echo "$USERNAME:$PASSWORD" | chpasswd
  usermod -aG sudo $USERNAME

  # configure ssh key for secure user
  SSHDIR="/home/$USERNAME/.ssh"
  mkdir $SSHDIR && echo "$SSHKEY" >> $SSHDIR/authorized_keys
  chmod -R 700 $SSHDIR && chmod 600 $SSHDIR/authorized_keys
  chown -R $USERNAME:$USERNAME $SSHDIR
fi

# Update system over IPv4 without any interaction
apt-get -o Acquire::ForceIPv4=true update
DEBIAN_FRONTEND=noninteractive \
apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages

# Configure hostname and configure entry to /etc/hosts
IPADDR=`hostname -I | awk '{ print $1 }'`

# Set FQDN and HOSTNAME if they aren't defined
if [ "$FQDN" == "" ]; then
  FQDN=`dnsdomainname -A | cut -d' ' -f1`
fi

if [ "$HOST" == "" ]; then
  HOSTNAME=`echo $FQDN | cut -d'.' -f1`
else
  HOSTNAME="$HOST"
fi

echo -e "$IPADDR\t$FQDN $HOSTNAME" >> /etc/hosts
hostnamectl set-hostname "$HOSTNAME"

# Configure timezone
timedatectl set-timezone "$TIMEZONE"

# Setup Firewall
apt-get -y install ufw
ufw default allow outgoing
ufw default deny incoming
ufw allow $SSH_PORT/tcp
ufw enable

# Setup Fail2ban
apt -y install fail2ban
cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
systemctl start fail2ban
systemctl enable fail2ban

# +----------------------------------------+
# | Docker
# +----------------------------------------+
## docker
apt-get -y install \
ca-certificates \
curl \
gnupg \
lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get -y update
apt-get -y install \
docker-ce \
docker-ce-cli \
containerd.io \
docker-compose-plugin

## docker-compose
curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

## ctop - top for containers
curl -fsSL https://azlux.fr/repo.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/azlux-archive-keyring.gpg
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian \
$(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azlux.list >/dev/null
apt-get update
apt-get install docker-ctop

## Finish docker
mkdir $DOCKER_FOLDER
usermod -a -G docker $USERNAME
systemctl enable --now docker

# +----------------------------------------+
# | Nginx Proxy Manager
# +----------------------------------------+
## Firewall
ufw allow 80/tcp
ufw allow 81/tcp
ufw allow 443/tcp

## Application Folder
mkdir $DOCKER_FOLDER/nginx-proxy-manager

## Docker compose file
printf \
"version: '3'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt" | tee $DOCKER_FOLDER/nginx-proxy-manager/docker-compose.yml > /dev/null

## Start container
docker-compose -f $DOCKER_FOLDER/nginx-proxy-manager/docker-compose.yml up -d