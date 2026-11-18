#!/bin/bash
# Prépare un serveur UP (Docker, Swarm, Portainer, outils et sauvegardes) sur une Debian 13 (trixie).
#
# Utilisé :
#   - par l'ISO Adipsys, à la fin de l'installation (dans le système installé, Docker ne tourne pas encore :
#     Portainer et le Swarm sont créés au premier démarrage par le service up-firstboot) ;
#   - sur une Debian 13 déjà installée par le client :
#       curl -fsSL https://raw.githubusercontent.com/Adipsys/public/main/bootstrap/up-bootstrap.sh -o up-bootstrap.sh
#       sudo bash up-bootstrap.sh
#     (Portainer et le Swarm sont alors créés immédiatement.)
#
# Options :
#   --force                     continuer même si le système n'est pas une Debian 13
#   --proxy URL                 proxy HTTP(S) pour sortir sur Internet (ex. http://proxy.client.fr:3128) ; « none » le retire
#   --no-proxy LISTE            destinations sans proxy, séparées par des virgules (localhost et 127.0.0.1 toujours ajoutés)
#   --dockerhub-mirror URL      miroir interne de Docker Hub (ex. https://nexus.client.fr:8443)
#   --adipsys-registry CHEMIN   registre interne qui réplique registry.adipsys.com (ex. harbor.client.fr/adipsys)
# Sans --proxy, le proxy saisi dans l'installateur Debian (configuration apt) est repris.
# Réglages conservés dans /etc/up/up.conf (une relance sans option les garde).
#
# Le script peut être relancé : les étapes déjà faites ne sont pas refaites.
# Journal : /var/log/up-bootstrap.log. Arrêt à la première erreur, étape en échec dans
# /var/lib/up/bootstrap.failed et dans le message de connexion (/etc/motd).

readonly LOG=/var/log/up-bootstrap.log
readonly STATE_DIR=/var/lib/up
readonly SUPPORT_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlwigpsyXHTU9hV+puWgXxLvaCffAaf5Stpp6OMrTzy support@adipsys.com'
readonly PUBLIC_REPO="https://github.com/Adipsys/public.git"
readonly TEMPLATES_URL="https://raw.githubusercontent.com/Adipsys/public/refs/heads/main/portainer-templates/templates.json"
readonly PACKAGES="ca-certificates curl wget gnupg git jq sudo openssh-server openssh-client htop nmon vim zstd \
net-tools rsync bash-completion smbclient cifs-utils unattended-upgrades open-vm-tools qemu-guest-agent whiptail"

FORCE=0
OPT_PROXY=""; OPT_NO_PROXY=""; OPT_DOCKERHUB_MIRROR=""; OPT_ADIPSYS_REGISTRY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --proxy) OPT_PROXY="${2:?URL du proxy manquante}"; shift ;;
        --no-proxy) OPT_NO_PROXY="${2:?liste manquante}"; shift ;;
        --dockerhub-mirror) OPT_DOCKERHUB_MIRROR="${2:?URL du miroir manquante}"; shift ;;
        --adipsys-registry) OPT_ADIPSYS_REGISTRY="${2:?registre manquant}"; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Option inconnue : $1"; exit 1 ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    echo "À lancer en root (sudo bash $0)."
    exit 1
fi

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1
set -Ee -o pipefail

on_error()
{
    local rc=$? line="$1" cmd="$2"
    # Échec d'une commande lancée par retry : afficher la commande plutôt que « return 1 ».
    if [ "$cmd" = "return 1" ] && [ -n "${RETRY_FAILED:-}" ]; then
        cmd="$RETRY_FAILED"
    fi
    echo "ÉCHEC de la préparation du serveur UP, ligne ${line} : ${cmd} (code ${rc})"
    echo "ligne ${line} : ${cmd} (code ${rc})" > "$STATE_DIR/bootstrap.failed"
    cat >> /etc/motd << EOM

!!! INSTALLATION INCOMPLÈTE : la préparation du serveur UP a échoué (ligne ${line} : ${cmd}).
!!! Voir ${LOG}. Le serveur n'est pas utilisable en l'état.
EOM
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# Réessaie une commande réseau (3 essais, 10 s d'écart).
retry()
{
    local attempt
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" -lt 3 ] && { echo "Échec de « $* », nouvel essai dans 10 s..."; sleep 10; }
    done
    RETRY_FAILED="$*"
    return 1
}

# Ajoute une ligne à la crontab de root si elle n'y est pas déjà.
add_cron()
{
    local line="$1"
    if ! crontab -l 2>/dev/null | grep -qxF "$line"; then
        (crontab -l 2>/dev/null || true; echo "$line") | crontab -
    fi
}

# systemd tourne-t-il ? (non pendant l'installation depuis l'ISO, où le script s'exécute en chroot)
systemd_running() { [ -d /run/systemd/system ]; }

echo "=== Préparation du serveur UP : $(date) ==="
rm -f "$STATE_DIR/bootstrap.failed"

# ------------------------------------------------------------------ Vérifications
. /etc/os-release
if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "trixie" ]; then
    echo "Système détecté : ${PRETTY_NAME:-inconnu}. Ce script est prévu pour Debian 13 (trixie)."
    [ "$FORCE" -eq 1 ] || { echo "Relancer avec --force pour continuer quand même."; exit 1; }
fi
if command -v docker > /dev/null && ! dpkg -s docker-ce > /dev/null 2>&1; then
    echo "Docker est déjà installé, mais pas depuis le dépôt officiel Docker (paquet docker.io ?)."
    echo "Le désinstaller avant de lancer ce script."
    exit 1
fi

# ------------------------------------------------------------------ Version du serveur
# L'ISO fournit /etc/up-release (version de l'ISO) ; sinon, installation par ce script.
[ -f /etc/up-release ] || echo 'UP_INSTALL_METHOD="bootstrap"' > /etc/up-release
grep -q '^UP_INSTALL_DATE=' /etc/up-release \
    || echo "UP_INSTALL_DATE=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> /etc/up-release
chmod 0644 /etc/up-release
. /etc/up-release
cat > /etc/motd << EOM
Serveur UP - ${UP_ISO_VERSION:+ISO ${UP_ISO_VERSION} - }installé le ${UP_INSTALL_DATE%%T*} (détails : /etc/up-release)
Installation des produits Adipsys : lancer « up-setup » (assistant).
EOM

# ------------------------------------------------------------------ Proxy et miroirs internes
# Réglages dans /etc/up/up.conf, lus aussi par up-firstboot, up-setup et up-update.
readonly UP_CONF=/etc/up/up.conf
install -d -m 0755 /etc/up
UP_HTTP_PROXY=""; UP_NO_PROXY=""; UP_DOCKERHUB_MIRROR=""; UP_ADIPSYS_REGISTRY=""
# shellcheck disable=SC1090
FIRST_RUN=1
if [ -f "$UP_CONF" ]; then . "$UP_CONF"; FIRST_RUN=0; fi
if [ -n "$OPT_PROXY" ]; then UP_HTTP_PROXY="$OPT_PROXY"; fi
if [ "$UP_HTTP_PROXY" = "none" ]; then UP_HTTP_PROXY=""; fi
if [ -n "$OPT_NO_PROXY" ]; then UP_NO_PROXY="$OPT_NO_PROXY"; fi
if [ -n "$OPT_DOCKERHUB_MIRROR" ]; then UP_DOCKERHUB_MIRROR="$OPT_DOCKERHUB_MIRROR"; fi
if [ -n "$OPT_ADIPSYS_REGISTRY" ]; then UP_ADIPSYS_REGISTRY="$OPT_ADIPSYS_REGISTRY"; fi
if [ -z "$UP_HTTP_PROXY" ] && [ -z "$OPT_PROXY" ] && [ "$FIRST_RUN" -eq 1 ]; then
    # Premier passage : proxy saisi dans l'installateur Debian (« Mandataire HTTP »), qu'il écrit dans /etc/apt/apt.conf.
    UP_HTTP_PROXY="$(sed -n 's/^Acquire::http::Proxy "\(.*\)";$/\1/p' /etc/apt/apt.conf 2>/dev/null | head -n 1)"
    case "$UP_HTTP_PROXY" in DIRECT|false) UP_HTTP_PROXY="" ;; esac
fi
# localhost et 127.0.0.1 toujours sans proxy (API Portainer locale).
UP_NO_PROXY="$(printf '%s' "localhost,127.0.0.1,${UP_NO_PROXY}" | tr ',' '\n' | sed '/^$/d' | awk '!seen[$0]++' | paste -sd, -)"

{
    echo "# Réglages réseau de la plateforme UP (up-bootstrap.sh). Relancer up-bootstrap.sh après modification."
    echo "UP_HTTP_PROXY=\"${UP_HTTP_PROXY}\""
    echo "UP_NO_PROXY=\"${UP_NO_PROXY}\""
    echo "UP_DOCKERHUB_MIRROR=\"${UP_DOCKERHUB_MIRROR}\""
    echo "UP_ADIPSYS_REGISTRY=\"${UP_ADIPSYS_REGISTRY}\""
} > "$UP_CONF"
chmod 0600 "$UP_CONF"

if [ -f /etc/environment ]; then
    sed -i '/^\(http\|https\|no\)_proxy=/Id' /etc/environment
fi
if [ -n "$UP_HTTP_PROXY" ]; then
    echo "--- Proxy : ${UP_HTTP_PROXY} (sans proxy : ${UP_NO_PROXY})"
    export http_proxy="$UP_HTTP_PROXY" https_proxy="$UP_HTTP_PROXY" no_proxy="$UP_NO_PROXY"
    export HTTP_PROXY="$UP_HTTP_PROXY" HTTPS_PROXY="$UP_HTTP_PROXY" NO_PROXY="$UP_NO_PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$UP_HTTP_PROXY" "$UP_HTTP_PROXY" \
        > /etc/apt/apt.conf.d/95up-proxy
    printf 'http_proxy=%s\nhttps_proxy=%s\nno_proxy=%s\nHTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' \
        "$UP_HTTP_PROXY" "$UP_HTTP_PROXY" "$UP_NO_PROXY" "$UP_HTTP_PROXY" "$UP_HTTP_PROXY" "$UP_NO_PROXY" \
        >> /etc/environment
else
    rm -f /etc/apt/apt.conf.d/95up-proxy
fi
if [ -n "$UP_DOCKERHUB_MIRROR" ]; then echo "--- Miroir Docker Hub : ${UP_DOCKERHUB_MIRROR}"; fi
if [ -n "$UP_ADIPSYS_REGISTRY" ]; then echo "--- Registre Adipsys interne : ${UP_ADIPSYS_REGISTRY}"; fi

# ------------------------------------------------------------------ Paquets et Docker
if [ -f /etc/apt/sources.list ]; then
    sed -i '/^deb cdrom/d' /etc/apt/sources.list
fi

echo "--- Paquets de base"
retry apt-get update
# shellcheck disable=SC2086
retry apt-get install -y $PACKAGES
if [ -n "$UP_HTTP_PROXY" ]; then
    git config --system http.proxy "$UP_HTTP_PROXY"
else
    git config --system --unset http.proxy 2>/dev/null || true
fi

echo "--- Docker"
# Configuration écrite avant l'installation : Docker démarre directement avec les bons réseaux.
mkdir -p /etc/docker
jq -n --arg proxy "$UP_HTTP_PROXY" --arg noproxy "$UP_NO_PROXY" --arg mirror "$UP_DOCKERHUB_MIRROR" '
    {
        "log-driver": "json-file",
        "log-opts": {"max-size": "2G", "max-file": "3"},
        "bip": "10.100.0.1/24",
        "default-address-pools": [{"base": "10.101.0.0/16", "size": 24}]
    }
    + (if $proxy != "" then {"proxies": {"http-proxy": $proxy, "https-proxy": $proxy, "no-proxy": $noproxy}} else {} end)
    + (if $mirror != "" then {"registry-mirrors": [$mirror]} else {} end)
' > /etc/docker/daemon.json
install -m 0755 -d /etc/apt/keyrings
retry curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
retry apt-get update
retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ------------------------------------------------------------------ Dossiers et accès
echo "--- Dossiers, accès support"
install -d -m 0700 /root/.ssh
install -d /root/ssl_certificates /root/traefik /backups/docker-engine /backups/docker-volumes /backups/docker-db
[ -f /root/traefik/traefik.yaml ] || touch /root/traefik/traefik.yaml
if ! grep -qsF "$SUPPORT_KEY" /root/.ssh/authorized_keys; then
    echo "$SUPPORT_KEY" >> /root/.ssh/authorized_keys
fi
chmod 0600 /root/.ssh/authorized_keys

# ------------------------------------------------------------------ Mises à jour automatiques
# Correctifs de sécurité Debian uniquement, sans redémarrage automatique.
# Docker est exclu : sa mise à jour redémarre tous les conteneurs (opération à planifier).
echo "--- Mises à jour de sécurité automatiques"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52up-unattended-upgrades << 'EOF'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker-buildx-plugin";
    "docker-compose-plugin";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# ------------------------------------------------------------------ Swarm et Portainer
# Service exécuté une seule fois (fichier témoin /var/lib/up/firstboot.done) ; en cas d'échec
# (ex. pas de réseau), il se relance toutes les 5 minutes et à chaque démarrage.
echo "--- Service up-firstboot (Swarm, Portainer)"
cat > /usr/local/sbin/up-firstboot.sh << EOF
#!/bin/bash
set -e

PORTAINER_IMAGE="portainer/portainer-ce:latest"
TEMPLATES_URL="${TEMPLATES_URL}"
EOF
cat >> /usr/local/sbin/up-firstboot.sh << 'EOF'

# Proxy et miroirs (up-bootstrap.sh --proxy / --dockerhub-mirror).
UP_HTTP_PROXY=""; UP_NO_PROXY=""; UP_DOCKERHUB_MIRROR=""
if [ -f /etc/up/up.conf ]; then . /etc/up/up.conf; fi

# Docker Hub joignable ? Directement (DNS), ou par le proxy / le miroir interne.
registry_reachable()
{
    if [ -n "$UP_HTTP_PROXY" ] || [ -n "$UP_DOCKERHUB_MIRROR" ]; then
        [ "$(curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' \
            ${UP_HTTP_PROXY:+--proxy "$UP_HTTP_PROXY"} "${UP_DOCKERHUB_MIRROR:-https://registry-1.docker.io}/v2/")" != "000" ]
    else
        getent hosts registry-1.docker.io > /dev/null
    fi
}

# Le réseau peut être déclaré prêt avant l'obtention du bail DHCP (interface en allow-hotplug) :
# on attend une route par défaut puis la résolution DNS du registre Docker (10 minutes maximum).
wait_network()
{
    local i
    for i in $(seq 1 60); do
        if { ip -4 route show default; ip -6 route show default; } 2>/dev/null | grep -q . \
            && registry_reachable; then
            return 0
        fi
        echo "Attente du réseau et du DNS ($i/60)..."
        sleep 10
    done
    echo "Réseau indisponible : Docker Hub ne répond pas${UP_HTTP_PROXY:+ (proxy $UP_HTTP_PROXY)}${UP_DOCKERHUB_MIRROR:+ (miroir $UP_DOCKERHUB_MIRROR)}."
    return 1
}

wait_network

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
    # Avec plusieurs adresses IP, Swarm refuse de choisir : on annonce celle de la route par défaut.
    ADVERTISE_ADDR="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n 1)"
    docker swarm init --default-addr-pool 10.200.0.0/16 ${ADVERTISE_ADDR:+--advertise-addr "$ADVERTISE_ADDR"}
    # Variante (ex. VMware, port VXLAN 4789 bloqué) : ajouter --data-path-port=9789
fi

docker volume inspect portainer_data > /dev/null 2>&1 || docker volume create portainer_data

if ! docker container inspect portainer > /dev/null 2>&1; then
    for attempt in 1 2 3 4 5; do
        docker pull "$PORTAINER_IMAGE" && break
        [ "$attempt" -eq 5 ] && exit 1
        echo "Échec du téléchargement de Portainer, nouvel essai dans 30 s..."
        sleep 30
    done
    PROXY_ENV=()
    if [ -n "$UP_HTTP_PROXY" ]; then
        PROXY_ENV=(-e "HTTP_PROXY=$UP_HTTP_PROXY" -e "HTTPS_PROXY=$UP_HTTP_PROXY" -e "NO_PROXY=$UP_NO_PROXY")
    fi
    docker run -d -p 8000:8000 -p 9443:9443 --name=portainer --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
        "${PROXY_ENV[@]}" "$PORTAINER_IMAGE" \
        --logo https://www.adipsys.com/wp-content/uploads/2020/07/UP-Logo.png \
        --templates "$TEMPLATES_URL"
fi

touch /var/lib/up/firstboot.done
EOF
chmod 0755 /usr/local/sbin/up-firstboot.sh

cat > /etc/systemd/system/up-firstboot.service << 'EOF'
[Unit]
Description=UP - premier démarrage (Portainer, Docker Swarm)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/up/firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/up-firstboot.sh
RemainAfterExit=yes
# En cas d'échec (réseau absent plus de 10 min...), nouvel essai toutes les 5 minutes.
Restart=on-failure
RestartSec=300

[Install]
WantedBy=multi-user.target
EOF
if systemd_running; then
    systemctl daemon-reload
fi
systemctl enable up-firstboot.service

# ------------------------------------------------------------------ Outils et sauvegardes
echo "--- Outils up-tools et sauvegardes"
if [ -d /usr/local/bin/public/.git ]; then
    retry git -C /usr/local/bin/public pull --ff-only
else
    retry git clone "$PUBLIC_REPO" /usr/local/bin/public
fi
add_cron '0 0 * * * /usr/local/bin/public/up-tools/docker-engine-backup.sh -s "/var/lib/docker/swarm" -t "/backups/docker-engine/" -d 30'
add_cron '5 0 * * * /usr/local/bin/public/up-tools/docker-volume-backup.sh -v "portainer_data" -t "/backups/docker-volumes/" -d 30'
add_cron '15 0 * * * /usr/local/bin/public/up-tools/docker-db-backup.sh -c all -t "/backups/docker-db/" -d 30'
ln -sf /usr/local/bin/public/up-tools/up-setup.sh /usr/local/sbin/up-setup
ln -sf /usr/local/bin/public/up-tools/up-update.sh /usr/local/sbin/up-update

# ------------------------------------------------------------------ Démarrage immédiat (hors ISO)
if systemd_running; then
    echo "--- Création du Swarm et de Portainer (quelques minutes)"
    systemctl restart docker
    systemctl start up-firstboot.service
    echo "Serveur prêt. Lancer maintenant l'assistant d'installation des produits : up-setup"
else
    echo "Swarm et Portainer seront créés au premier démarrage (service up-firstboot), puis lancer « up-setup »."
fi

touch "$STATE_DIR/bootstrap.done"
echo "=== Préparation du serveur UP terminée : $(date) ==="
