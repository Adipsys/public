#!/usr/bin/env bash
# Assistant d'installation Adipsys UP! (mode texte).
#
# À lancer en root sur un serveur préparé par l'ISO Adipsys ou par up-bootstrap.sh :
#     up-setup
#     up-setup agent      installe seulement l'agent d'inventaire (serveur déjà configuré)
#
# Étapes :
#   1. vérifications : ressources, accès Internet (licences, registre, mises à jour), heure ;
#   2. Portainer : compte administrateur, clé d'API (pour up-update.sh) ;
#   3. registre Adipsys : identifiants vérifiés puis enregistrés dans Portainer ;
#   4. Traefik (reverse proxy), déployé en premier ;
#   5. produits (Hotspot Manager, DNS Protect, STUDIO) : questions réduites au nécessaire,
#      mots de passe générés, vérification des noms DNS, déploiement et attente ;
#   6. agent d'inventaire (up-agent), installé d'office : jeton d'enrôlement embarqué dans l'ISO
#      (/etc/up/registry.env) ou demandé, nom du client facultatif ;
#   7. récapitulatif : adresses, identifiants, ports à ouvrir, étapes restantes.
#
# Les définitions des produits (champs, valeurs par défaut) viennent de portainer-templates/templates.json,
# les stacks de stacks/*.yml : l'assistant déploie exactement la même chose que les App Templates.
#
# Fichiers produits (root uniquement) :
#   /root/up-secrets.env           mots de passe générés
#   /root/.up-update.conf          clé d'API Portainer (utilisée aussi par up-update.sh)
#   /root/up-install-report.txt    récapitulatif pour le client et le support
# Journal : /var/log/up-setup.log

set -Eeuo pipefail
umask 077

readonly SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly REPO_DIR="${UP_REPO_DIR:-$(dirname "$SELF_DIR")}"
readonly TEMPLATES="${REPO_DIR}/portainer-templates/templates.json"
readonly CONF_FILE="${UP_UPDATE_CONF:-/root/.up-update.conf}"
readonly SECRETS_FILE="${UP_SECRETS_FILE:-/root/up-secrets.env}"
readonly REPORT_FILE="${UP_REPORT_FILE:-/root/up-install-report.txt}"
readonly LOG_FILE="${UP_SETUP_LOG:-/var/log/up-setup.log}"
readonly PORTAINER_URL="${PORTAINER_URL:-https://127.0.0.1:9443}"
# Console d'inventaire du support Adipsys, à laquelle l'agent up-agent envoie ses rapports.
readonly UP_CONSOLE_URL="${UP_CONSOLE_URL:-https://up-console.adipsys.net}"

# Proxy et miroirs internes (up-bootstrap.sh --proxy / --dockerhub-mirror / --adipsys-registry).
UP_HTTP_PROXY=""; UP_NO_PROXY="localhost,127.0.0.1"; UP_DOCKERHUB_MIRROR=""; UP_ADIPSYS_REGISTRY=""
# shellcheck disable=SC1090
if [[ -f "${UP_NETWORK_CONF:-/etc/up/up.conf}" ]]; then source "${UP_NETWORK_CONF:-/etc/up/up.conf}"; fi
if [[ -n "$UP_HTTP_PROXY" ]]; then
    export http_proxy="$UP_HTTP_PROXY" https_proxy="$UP_HTTP_PROXY" no_proxy="$UP_NO_PROXY"
    export HTTP_PROXY="$UP_HTTP_PROXY" HTTPS_PROXY="$UP_HTTP_PROXY" NO_PROXY="$UP_NO_PROXY"
fi
# Registre des images Adipsys : public, ou registre interne du client qui le réplique.
readonly ADIPSYS_IMAGES="${UP_ADIPSYS_REGISTRY:-registry.adipsys.com}"
readonly REGISTRY="${ADIPSYS_IMAGES%%/*}"
readonly TITLE="Adipsys UP! - Assistant d'installation"
readonly WAIT_TIMEOUT="${UP_SETUP_TIMEOUT:-1200}"
WAIT_FAILURE=""
readonly POLL="${UP_SETUP_POLL:-10}"

API_KEY=""
ENDPOINT_ID=""
SWARM_ID=""
INSTALLED=()      # "stack|template" des produits déployés pendant cette exécution
REPORT_LINES=()

# ---------------------------------------------------------------- Outils

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true; }

ui()          { whiptail --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }
msg()         { ui --msgbox "$1" "${2:-16}" 76; }
ask_yesno()   { ui --yesno "$1" "${2:-12}" 76; }
ask_input()   { ui --inputbox "$1" 12 76 "${2:-}"; }
ask_secret()  { ui --passwordbox "$1" 10 76; }

abort()
{
    log "Arrêt : $*"
    clear 2>/dev/null || true
    echo "Installation interrompue : $*"
    echo "Relancer « up-setup » pour reprendre (les étapes déjà faites sont conservées)."
    exit 1
}

# whiptail renvoie 1 sur « Annuler » : on propose de quitter.
ask_or_quit()
{
    local answer
    if answer="$("$@")"; then
        printf '%s' "$answer"
    else
        abort "annulé par l'utilisateur"
    fi
}

gen_password()
{
    local pw
    pw="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    printf '%s' "${pw:0:20}"
}

save_secret()
{
    local key="$1" value="$2"
    touch "$SECRETS_FILE" && chmod 600 "$SECRETS_FILE"
    grep -v "^${key}=" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp" || true
    printf '%s=%q\n' "$key" "$value" >> "${SECRETS_FILE}.tmp"
    mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
}

report() { REPORT_LINES+=("$1"); }

# ---------------------------------------------------------------- Portainer API

api()
{
    local method="$1" path="$2"
    shift 2
    local auth=()
    [[ -n "$API_KEY" ]] && auth=(--header "X-API-Key: ${API_KEY}")
    curl --fail --silent --show-error --insecure --noproxy '*' ${auth[@]+"${auth[@]}"} \
        --request "$method" "$@" "${PORTAINER_URL}/api${path}"
}

api_status()
{
    curl --silent --insecure --noproxy '*' --output /dev/null --write-out '%{http_code}' \
        --request "$1" "${PORTAINER_URL}/api$2" || true
}

# ---------------------------------------------------------------- Templates

template_json() { jq -e --arg n "$1" '.templates[] | select(.name == $n)' "$TEMPLATES"; }

stack_file_of() { jq -r '.repository.stackfile' <<< "$1" | sed 's#^/##'; }

# Libellés en français pour les champs connus (sinon le libellé du template).
field_label()
{
    case "$1" in
        OPERATOR)               echo "Nom de votre société (sans espace ni caractère spécial, ex. : MaSociete)" ;;
        HM_SERVER_NAME)         echo "Nom du serveur Hotspot Manager (ex. : wifi → wifi.domaine.fr, wifi-admin.domaine.fr, wifi-api.domaine.fr)" ;;
        HM_URL_SUFFIX)          echo "Votre domaine (ex. : domaine.fr)" ;;
        SERVER_NAME)            echo "Adresse de l'interface DNS Protect (ex. : dnsprotect.domaine.fr)" ;;
        STUDIO_NAME)            echo "Adresse de l'interface STUDIO (ex. : studio.domaine.fr)" ;;
        OPERATOR_SUPPORT_EMAIL) echo "E-mail du support de votre société" ;;
        PRODUCT_VERSION)        echo "Version à installer" ;;
        TZ)                     echo "Fuseau horaire" ;;
        *)                      echo "$2" ;;
    esac
}

valid_value()
{
    case "$1" in
        OPERATOR)       [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] ;;
        HM_SERVER_NAME) [[ "$2" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ;;
        HM_URL_SUFFIX|SERVER_NAME|STUDIO_NAME) [[ "$2" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] ;;
        *_EMAIL)        [[ "$2" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ;;
        *_PORT)         [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 && $2 < 65536 )) ;;
        *)              [[ -n "$2" ]] ;;
    esac
}

is_secret_field() { [[ "$1" =~ PASSWORD|PASSWD ]]; }

# Noms DNS à créer pour un produit (d'après ses variables).
product_hostnames()
{
    local env_json="$1"
    local hm sfx srv studio
    hm="$(jq -r '.[] | select(.name=="HM_SERVER_NAME") | .value' <<< "$env_json")"
    sfx="$(jq -r '.[] | select(.name=="HM_URL_SUFFIX") | .value' <<< "$env_json")"
    srv="$(jq -r '.[] | select(.name=="SERVER_NAME") | .value' <<< "$env_json")"
    studio="$(jq -r '.[] | select(.name=="STUDIO_NAME") | .value' <<< "$env_json")"
    if [[ -n "$hm" && -n "$sfx" ]]; then
        printf '%s\n' "${hm}.${sfx}" "${hm}-admin.${sfx}" "${hm}-api.${sfx}"
    fi
    [[ -n "$srv" ]] && echo "$srv"
    [[ -n "$studio" ]] && echo "$studio"
    return 0
}

admin_url_of()
{
    local env_json="$1" hosts
    hosts="$(product_hostnames "$env_json")"
    if grep -q -- '-admin\.' <<< "$hosts"; then
        grep -- '-admin\.' <<< "$hosts" | head -n 1
    else
        head -n 1 <<< "$hosts"
    fi
}

# ---------------------------------------------------------------- 1. Vérifications

check_url()
{
    # Toute réponse HTTP (même 401/404) prouve que le flux est ouvert.
    local code
    code="$(curl --silent --insecure --output /dev/null --max-time 8 --write-out '%{http_code}' "$1" || true)"
    [[ "$code" != "000" ]]
}

step_checks()
{
    local cpus mem_gb disk_gb out="" failed=0 target name url
    cpus="$(nproc)"
    mem_gb="$(awk '/MemTotal/ {printf "%d", ($2 + 524288) / 1048576}' /proc/meminfo)"
    disk_gb="$(df -BG --output=size /var/lib/docker 2>/dev/null | tail -n 1 | tr -dc '0-9' || echo 0)"

    out+="Ressources : ${cpus} vCPU, ${mem_gb} Go de RAM, ${disk_gb} Go de disque (Docker)\n"
    out+="  Minimum : HM seul 4 vCPU / 4 Go, DNS Protect 4 vCPU / 8 Go,\n"
    out+="            plusieurs produits 8 vCPU / 16 Go. Disque conseillé : 100 Go SSD.\n"
    if (( cpus < 4 || mem_gb < 4 )); then
        out+="  ⚠ Ressources insuffisantes pour un produit Adipsys.\n"; failed=1
    fi
    (( disk_gb >= 95 )) || out+="  ⚠ Moins de 100 Go de disque.\n"

    out+="\nAccès Internet depuis le serveur${UP_HTTP_PROXY:+ (par le proxy ${UP_HTTP_PROXY})} :\n"
    for target in \
        "Licences|https://licences.adipsys.com" \
        "Registre Adipsys (${REGISTRY})|https://${REGISTRY}/v2/" \
        "Docker Hub${UP_DOCKERHUB_MIRROR:+ (miroir)}|${UP_DOCKERHUB_MIRROR:-https://registry-1.docker.io}/v2/" \
        "GitHub (templates, outils)|https://raw.githubusercontent.com" \
        "Console d'inventaire Adipsys|${UP_CONSOLE_URL}" \
        "Mises à jour Debian|https://deb.debian.org"; do
        name="${target%%|*}"; url="${target#*|}"
        if check_url "$url"; then
            out+="  OK      ${name}\n"
        else
            out+="  BLOQUÉ  ${name} (${url%%/v2/})\n"; failed=1
        fi
    done

    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
        out+="  OK      Heure synchronisée (NTP)\n"
    else
        out+="  ⚠       Heure non synchronisée : vérifier l'accès NTP (port 123)\n"
    fi
    log "Vérifications :\n${out}"

    if (( failed )); then
        out+="\nCorriger les points bloquants (pare-feu, proxy, ressources) avant de continuer.\n"
        out+="Continuer quand même ?"
        ask_yesno "$(printf '%b' "$out")" 24 || abort "vérifications à corriger"
    else
        msg "$(printf '%b' "$out")\nTout est prêt." 22
    fi
}

# ---------------------------------------------------------------- 2. Portainer

wait_portainer()
{
    local i
    for i in $(seq 1 60); do
        [[ "$(api_status GET /system/status)" == "200" ]] && return 0
        if (( i == 1 )); then
            echo "Attente de Portainer (création au premier démarrage)..."
            if [[ ! -f /var/lib/up/firstboot.done ]]; then
                systemctl start up-firstboot.service 2>/dev/null || true
            fi
        fi
        sleep 5
    done
    abort "Portainer ne répond pas sur ${PORTAINER_URL} (voir « systemctl status up-firstboot »)"
}

create_api_key()
{
    local user="$1" password="$2" jwt user_id key
    jwt="$(api POST /auth --header 'Content-Type: application/json' \
        --data "$(jq -n --arg u "$user" --arg p "$password" '{username: $u, password: $p}')" | jq -r '.jwt')" \
        || return 1
    user_id="$(curl --fail --silent --insecure --noproxy '*' --header "Authorization: Bearer ${jwt}" \
        "${PORTAINER_URL}/api/users/me" | jq -r '.Id' || echo 1)"
    key="$(curl --fail --silent --insecure --noproxy '*' --header "Authorization: Bearer ${jwt}" \
        --header 'Content-Type: application/json' --request POST \
        --data "$(jq -n --arg p "$password" '{description: "up-setup / up-update", password: $p}')" \
        "${PORTAINER_URL}/api/users/${user_id}/tokens" | jq -r '.rawAPIKey')"
    [[ -n "$key" && "$key" != "null" ]] || return 1
    API_KEY="$key"
    install -m 600 /dev/null "$CONF_FILE"
    printf 'PORTAINER_API_KEY="%s"\n' "$API_KEY" > "$CONF_FILE"
}

# Création du compte administrateur ; en cas de refus, le code HTTP et la réponse vont dans le journal.
# Portainer récent : la création du compte exige le jeton affiché dans ses journaux au démarrage
# (en-tête X-Setup-Token, ligne « setup_token=… »), nouveau à chaque démarrage : on lit les journaux
# du démarrage en cours seulement. Vide sur les versions plus anciennes.
setup_token()
{
    local since
    since="$(docker inspect --format '{{.State.StartedAt}}' portainer 2>/dev/null || true)"
    docker logs ${since:+--since "$since"} portainer 2>&1 \
        | grep -ioE 'setup[ _-]?token[^A-Za-z0-9]{1,6}[A-Za-z0-9_-]{8,}' \
        | tail -n 1 | grep -oE '[A-Za-z0-9_-]{8,}$' || true
}

admin_init()
{
    local body code token header=()
    token="$(setup_token)"
    [[ -n "$token" ]] && header=(--header "X-Setup-Token: ${token}")
    body="$(mktemp)"
    code="$(curl --silent --insecure --noproxy '*' --output "$body" --write-out '%{http_code}' \
        ${header[@]+"${header[@]}"} \
        --request POST --header 'Content-Type: application/json' \
        --data "$(jq -n --arg u "$1" --arg p "$2" '{Username: $u, Password: $p}')" \
        "${PORTAINER_URL}/api/users/admin/init" || true)"
    if [[ "$code" == "200" ]]; then
        rm -f "$body"
        return 0
    fi
    log "Portainer /users/admin/init : HTTP ${code} (jeton de setup $([[ -n "$token" ]] && echo trouvé || echo absent)) $(head -c 300 "$body" | tr '\n' ' ')"
    rm -f "$body"
    return 1
}

step_portainer()
{
    local status user password

    wait_portainer

    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
        API_KEY="${PORTAINER_API_KEY:-}"
        if [[ -n "$API_KEY" && "$(curl --silent --insecure --noproxy '*' --output /dev/null --write-out '%{http_code}' \
                --header "X-API-Key: ${API_KEY}" "${PORTAINER_URL}/api/users/me" || true)" == "200" ]]; then
            log "Clé d'API existante utilisée"
            return 0
        fi
        API_KEY=""
    fi

    status="$(api_status GET /users/admin/check)"
    if [[ "$status" == "404" ]]; then
        # Pas encore de compte administrateur : on le crée.
        user="admin"
        password="$(gen_password)"
        if ! admin_init "$user" "$password"; then
            # Portainer refuse la création après quelques minutes : on le redémarre.
            log "Création du compte refusée, redémarrage de Portainer"
            docker restart portainer > /dev/null
            wait_portainer
            local i ok=0
            for i in 1 2 3 4 5 6; do
                if admin_init "$user" "$password"; then ok=1; break; fi
                sleep 5
            done
            (( ok )) || abort "impossible de créer le compte administrateur Portainer (détail dans ${LOG_FILE})"
        fi
        save_secret PORTAINER_ADMIN_USER "$user"
        save_secret PORTAINER_ADMIN_PASSWORD "$password"
        report "Portainer : https://$(primary_ip):9443  —  compte « ${user} », mot de passe dans ${SECRETS_FILE}"
        msg "Compte administrateur Portainer créé :\n\n  Utilisateur : ${user}\n  Mot de passe : ${password}\n\nNotez-le : il est aussi enregistré dans ${SECRETS_FILE} (lisible par root uniquement)." 14
    else
        user="$(ask_or_quit ask_input "Un compte administrateur Portainer existe déjà.\nNom d'utilisateur :" "admin")"
        password="$(ask_or_quit ask_secret "Mot de passe Portainer de « ${user} » :")"
    fi

    create_api_key "$user" "$password" || abort "connexion à Portainer impossible (identifiants ?)"
    log "Clé d'API Portainer créée"
}

load_environment()
{
    ENDPOINT_ID="$(api GET /endpoints | jq -r '[.[] | select(.Type == 1 or .Type == 2)] | first | .Id // empty')"
    if [[ -z "$ENDPOINT_ID" ]]; then
        # Environnement Docker local pas encore créé (première connexion à Portainer).
        ENDPOINT_ID="$(api POST /endpoints --form Name=local --form EndpointCreationType=1 | jq -r '.Id')"
    fi
    SWARM_ID="$(api GET "/endpoints/${ENDPOINT_ID}/docker/swarm" | jq -r '.ID')"
    [[ -n "$SWARM_ID" && "$SWARM_ID" != "null" ]] || abort "Docker Swarm n'est pas initialisé (voir « systemctl status up-firstboot »)"
    log "Environnement Portainer ${ENDPOINT_ID}, Swarm ${SWARM_ID}"
}

# ---------------------------------------------------------------- 3. Registre

step_registry()
{
    local user password code

    if api GET /registries | jq -e --arg r "$REGISTRY" '.[] | select(.URL == $r)' > /dev/null; then
        log "Registre déjà enregistré"
        return 0
    fi

    # Identifiants fournis par l'environnement (REGISTRY_USER / REGISTRY_PASSWORD) ou embarqués dans l'ISO
    # (/etc/up/registry.env, root 600) : utilisés sans question s'ils sont acceptés par le registre.
    # Ils ne doivent jamais être écrits dans ce dépôt public.
    if [[ -z "${REGISTRY_PASSWORD:-}" && -r "${REGISTRY_ENV_FILE:-/etc/up/registry.env}" ]]; then
        local UP_REGISTRY_USER="" UP_REGISTRY_PASSWORD=""
        # shellcheck disable=SC1090
        source "${REGISTRY_ENV_FILE:-/etc/up/registry.env}"
        REGISTRY_USER="${REGISTRY_USER:-$UP_REGISTRY_USER}"
        REGISTRY_PASSWORD="$UP_REGISTRY_PASSWORD"
    fi
    if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
        code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 \
            --user "${REGISTRY_USER}:${REGISTRY_PASSWORD}" "https://${REGISTRY}/v2/" || true)"
        if [[ "$code" == "200" ]]; then
            user="$REGISTRY_USER"
            password="$REGISTRY_PASSWORD"
        else
            log "Identifiants du registre de l'environnement refusés (HTTP ${code})"
        fi
    fi

    while [[ -z "${password:-}" ]]; do
        user="$(ask_or_quit ask_input "Identifiant du registre ${REGISTRY}\n(fourni par Adipsys avec votre licence) :" "${REGISTRY_USER:-}")"
        password="$(ask_or_quit ask_secret "Mot de passe du registre ${REGISTRY} :")"
        code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 \
            --user "${user}:${password}" "https://${REGISTRY}/v2/" || true)"
        [[ "$code" == "200" ]] && break
        password=""
        ask_yesno "Identifiants refusés par ${REGISTRY} (code HTTP ${code}).\n\nRessaisir ?" 10 || abort "identifiants du registre invalides"
    done

    api POST /registries --header 'Content-Type: application/json' \
        --data "$(jq -n --arg r "$REGISTRY" --arg u "$user" --arg p "$password" \
            '{Name: $r, Type: 3, URL: $r, Authentication: true, Username: $u, Password: $p}')" > /dev/null
    log "Registre ${REGISTRY} enregistré"
}

# ---------------------------------------------------------------- Déploiement

stack_exists() { api GET /stacks | jq -e --arg n "$1" '.[] | select(.Name == $n)' > /dev/null; }

# Remplace ${NOM} et ${NOM:-défaut} par les valeurs de la liste de variables JSON $2.
resolve_vars()
{
    local text="$1" env_json="$2" name value
    while [[ "$text" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\} ]]; do
        name="${BASH_REMATCH[1]}"
        value="$(jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .value) // empty' <<< "$env_json")"
        [[ -n "$value" ]] || value="${BASH_REMATCH[3]}"
        text="${text/"${BASH_REMATCH[0]}"/$value}"
    done
    printf '%s' "$text"
}

# Ports publiés par un fichier de stack (« port/protocole », un par ligne), variables résolues avec $2.
# Gère la syntaxe courte (- "8080:80/udp") et longue (target / published / protocol).
stack_ports()
{
    local file="$1" env_json="$2" published proto
    awk -v q="'" '
        function flush() { if (pub != "") print pub, (proto == "" ? "tcp" : proto); pub = ""; proto = "" }
        /^[ \t]*ports:[ \t]*$/ { inp = 1; ind = match($0, /[^ ]/); next }
        inp {
            if ($0 ~ /^[ \t]*(#.*)?$/) next
            if (match($0, /[^ ]/) <= ind) { flush(); inp = 0; next }
            line = $0; gsub(/"/, "", line); gsub(q, "", line); sub(/^[ \t]+/, "", line)
            if (line ~ /^- target:/) { flush(); next }
            if (line ~ /^- /) {
                flush(); sub(/^- /, "", line)
                n = split(line, a, "/"); spec = a[1]; pr = (n > 1 ? a[2] : "tcp")
                if (spec ~ /^[0-9]+$/) next            # port du conteneur seul : non publié
                sub(/:[^:]*$/, "", spec); print spec, pr; next
            }
            if (line ~ /^published:/) { sub(/^published:[ \t]*/, "", line); pub = line }
            if (line ~ /^protocol:/)  { sub(/^protocol:[ \t]*/, "", line); proto = line }
        }
        END { flush() }' "${REPO_DIR}/${file}" \
    | while read -r published proto; do
        published="$(resolve_vars "$published" "$env_json")"
        published="${published##*:}"                    # « IP:port » : garder le port
        [[ "$published" =~ ^[0-9]+$ ]] && echo "${published}/${proto}"
    done | sort -u
}

# Ports déjà pris sur ce serveur : « port/protocole propriétaire », un par ligne.
used_ports()
{
    local id
    for id in $(docker service ls -q 2>/dev/null); do
        docker service inspect "$id" --format \
            '{{$n := .Spec.Name}}{{if .Spec.EndpointSpec}}{{range .Spec.EndpointSpec.Ports}}{{.PublishedPort}}/{{.Protocol}} service {{$n}}{{"\n"}}{{end}}{{end}}' 2>/dev/null
    done
    ss -Hlntu 2>/dev/null | awk '{ n = split($5, a, ":"); print a[n] "/" $1 " processus du serveur" }'
}

# Ports de la stack $1 (variables $2) déjà utilisés : « port/protocole : propriétaire », un par ligne.
port_conflicts()
{
    local wanted used port owner
    wanted="$(stack_ports "$1" "$2")"
    [[ -n "$wanted" ]] || return 0
    used="$(used_ports | sort -u)"
    while read -r port; do
        owner="$(awk -v p="$port" '$1 == p { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$used")"
        [[ -n "$owner" ]] && echo "  ${port} : ${owner}"
    done <<< "$wanted"
    return 0
}

deploy_stack()
{
    local name="$1" file="$2" env_json="$3" payload
    payload="$(jq -n --arg n "$name" --arg s "$SWARM_ID" --rawfile f "${REPO_DIR}/${file}" --argjson e "$env_json" \
        '{Name: $n, SwarmID: $s, StackFileContent: $f, Env: $e}')"
    # Portainer récent, puis ancienne route en repli.
    api POST "/stacks/create/swarm/string?endpointId=${ENDPOINT_ID}" \
            --header 'Content-Type: application/json' --data "$payload" > /dev/null 2>>"$LOG_FILE" \
        || api POST "/stacks?type=1&method=string&endpointId=${ENDPOINT_ID}" \
            --header 'Content-Type: application/json' --data "$payload" > /dev/null
}

# Attend que tous les services de la stack tournent.
wait_stack()
{
    local stack="$1" deadline service mode running desired pending empty_deadline
    deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
    # Aucun service après 2 minutes : le déploiement a échoué (ex. port déjà utilisé), inutile d'attendre.
    empty_deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if [[ -z "$(docker stack services "$stack" -q 2>/dev/null)" ]] && (( $(date +%s) >= empty_deadline )); then
            echo "  ${stack} : aucun service créé, le déploiement a échoué (voir Portainer → Stacks → ${stack})."
            log "Stack ${stack} : aucun service créé après 2 min"
            WAIT_FAILURE="aucun service créé : le déploiement a échoué (erreur dans Portainer → Stacks → ${stack})"
            return 1
        fi
        pending=0
        for service in $(docker stack services "$stack" --format '{{.Name}}' 2>/dev/null); do
            mode="$(docker service inspect -f '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{else}}global{{end}}' "$service")"
            running="$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)"
            if [[ "$mode" == "global" ]]; then desired=1; else desired="$mode"; fi
            (( running >= desired )) || pending=$((pending + 1))
        done
        if (( pending == 0 )) && [[ -n "$(docker stack services "$stack" -q 2>/dev/null)" ]]; then
            return 0
        fi
        echo "  ${stack} : ${pending} service(s) en cours de démarrage (téléchargement des images...)"
        sleep "$POLL"
    done
    WAIT_FAILURE="tous les services ne sont pas démarrés après $((WAIT_TIMEOUT / 60)) min (voir Portainer → Stacks → ${stack})"
    return 1
}

# Ajoute HTTP_PROXY / HTTPS_PROXY / NO_PROXY à une liste de variables si un proxy est configuré.
# NO_PROXY reçoit aussi les noms des services de la stack (échanges internes sans proxy).
with_proxy_env()
{
    local env_json="$1" file="$2" services no_proxy
    [[ -n "$UP_HTTP_PROXY" ]] || { printf '%s' "$env_json"; return 0; }
    services="$(awk '/^services:/ {s = 1; next} s && /^  [a-z0-9-]+:$/ {gsub(/[ :]/, ""); print}' "${REPO_DIR}/${file}" | paste -sd, -)"
    no_proxy="${UP_NO_PROXY}${services:+,${services}}"
    jq --arg p "$UP_HTTP_PROXY" --arg n "$no_proxy" \
        '. + [{name: "HTTP_PROXY", value: $p}, {name: "HTTPS_PROXY", value: $p}, {name: "NO_PROXY", value: $n}]' <<< "$env_json"
}

# ---------------------------------------------------------------- 4. Traefik

step_traefik()
{
    local tpl env_json conflicts
    if stack_exists traefik; then
        log "Traefik déjà déployé"
        return 0
    fi
    tpl="$(template_json traefik)"
    env_json="$(jq '[.env[]? | {name: .name, value: (.default // "")}]' <<< "$tpl")"
    env_json="$(with_proxy_env "$env_json" "$(stack_file_of "$tpl")")"
    conflicts="$(port_conflicts "$(stack_file_of "$tpl")" "$env_json")"
    [[ -z "$conflicts" ]] || abort "Traefik ne peut pas être installé, ports déjà utilisés :
${conflicts}
Arrêter le service qui les occupe (ex. serveur web installé sur le système), puis relancer up-setup"
    echo "Déploiement de Traefik..."
    deploy_stack traefik "$(stack_file_of "$tpl")" "$env_json"
    wait_stack traefik || abort "Traefik ne démarre pas (voir Portainer → Stacks → traefik)"
    log "Traefik déployé"
}

# ---------------------------------------------------------------- 5. Produits

primary_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n 1; }

# Vérifie que les noms DNS pointent vers ce serveur ; renvoie un texte pour l'affichage.
check_dns()
{
    local hosts="$1" host resolved local_ips out="" ok=1
    local_ips=" $(hostname -I 2>/dev/null) "
    while read -r host; do
        [[ -n "$host" ]] || continue
        resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
        if [[ -z "$resolved" ]]; then
            out+="  ✗ ${host} : n'existe pas dans le DNS\n"; ok=0
        elif [[ "$local_ips" == *" ${resolved%% *} "* ]]; then
            out+="  ✓ ${host} → ${resolved}\n"
        else
            out+="  ? ${host} → ${resolved}(IP publique / NAT vers ce serveur ?)\n"
        fi
    done <<< "$hosts"
    printf '%b' "$out"
    return $(( 1 - ok ))
}

configure_product()
{
    local name="$1" tpl="$2" env_json="[]" field label default preset value advanced=1 secrets=""

    ask_yesno "Garder les réglages par défaut (version, ports, fuseau horaire) ?\n\n« Non » pour les modifier." 10 && advanced=0

    while IFS=$'\t' read -r field label default preset; do
        [[ "$default" == "null" ]] && default=""
        if [[ "$field" == "PRODUCT_SOURCE" ]]; then
            value="${default/registry.adipsys.com/$ADIPSYS_IMAGES}"
        elif [[ "$preset" == "true" ]]; then
            value="$default"
        elif is_secret_field "$field"; then
            value="$(gen_password)"
            save_secret "$(tr "a-z-" "A-Z_" <<< "$name")_${field}" "$value"
            secrets+="  ${field} : ${value}\n"
        elif [[ -n "$default" && "$advanced" -eq 0 && ! " HM_SERVER_NAME OPERATOR_SUPPORT_EMAIL " =~ " ${field} " ]]; then
            value="$default"
        else
            while true; do
                value="$(ask_or_quit ask_input "$(field_label "$field" "$label")" "$default")"
                valid_value "$field" "$value" && break
                msg "Valeur invalide pour ${field} : « ${value} »" 8
            done
        fi
        env_json="$(jq --arg n "$field" --arg v "$value" '. + [{name: $n, value: $v}]' <<< "$env_json")"
    done < <(jq -r '.env[]? | [.name, (.label // .name), (.default // "null"), (.preset // false | tostring)] | @tsv' <<< "$tpl")

    # Certificats : Let's Encrypt automatique ou certificat fourni (/root/ssl_certificates).
    if [[ "$name" != "rsyslog" ]] && ask_yesno "Certificats HTTPS : utiliser Let's Encrypt (gratuit, automatique) ?\n\nNécessite que les noms DNS pointent vers ce serveur et que le port 80\nsoit joignable depuis Internet.\n\n« Non » : vous déposerez votre certificat dans /root/ssl_certificates." 14; then
        env_json="$(jq '. + [{name: "TLS_RESOLVER", value: "letsencrypt"}]' <<< "$env_json")"
    fi

    [[ -n "$secrets" ]] && msg "Mots de passe générés pour ${name} (enregistrés dans ${SECRETS_FILE}) :\n\n${secrets}" 14
    printf '%s' "$env_json"
}

install_product()
{
    local name="$1" tpl env_json stack hosts dns_text conflicts

    tpl="$(template_json "$name")"
    stack="$(ask_or_quit ask_input "Nom de la stack dans Portainer pour $(jq -r .title <<< "$tpl") :" "$name")"
    if stack_exists "$stack"; then
        msg "La stack « ${stack} » existe déjà : elle n'est pas modifiée." 8
        return 0
    fi

    env_json="$(configure_product "$name" "$tpl")"
    env_json="$(with_proxy_env "$env_json" "$(stack_file_of "$tpl")")"

    conflicts="$(port_conflicts "$(stack_file_of "$tpl")" "$env_json")"
    if [[ -n "$conflicts" ]]; then
        msg "$(jq -r .title <<< "$tpl") n'est pas installé : ports déjà utilisés sur ce serveur :\n\n${conflicts}\n\nPour choisir d'autres ports, relancez up-setup et répondez « Non »\nà « Garder les réglages par défaut »." 18
        report "⚠ ${stack} non installé : ports déjà utilisés ($(sed 's/^ *//' <<< "$conflicts" | paste -sd, -))"
        log "Ports déjà utilisés pour ${stack} :\n${conflicts}"
        return 0
    fi

    hosts="$(product_hostnames "$env_json")"
    if [[ -n "$hosts" ]]; then
        if ! dns_text="$(check_dns "$hosts")"; then
            ask_yesno "Noms DNS à créer (vers l'IP de ce serveur : $(primary_ip)) :\n\n${dns_text}\nCertains noms n'existent pas encore. Le produit sera installé mais injoignable\ntant qu'ils ne sont pas créés.\n\nContinuer ?" 20 || abort "noms DNS à créer"
        else
            msg "Noms DNS :\n\n${dns_text}" 14
        fi
    fi

    clear 2>/dev/null || true
    echo "Déploiement de ${stack}..."
    deploy_stack "$stack" "$(stack_file_of "$tpl")" "$env_json"
    log "Stack ${stack} (${name}) déployée"
    WAIT_FAILURE=""
    if wait_stack "$stack"; then
        INSTALLED+=("${stack}|${name}|$(admin_url_of "$env_json")")
    else
        report "⚠ ${stack} : ${WAIT_FAILURE}"
        INSTALLED+=("${stack}|${name}|$(admin_url_of "$env_json")")
    fi
    [[ -n "$hosts" ]] && report "Noms DNS pour ${stack} (vers $(primary_ip)) : $(tr '\n' ' ' <<< "$hosts")"
}

step_products()
{
    local choices name
    choices="$(ask_or_quit ui --checklist "Produits à installer (espace pour cocher) :" 14 76 3 \
        hotspotmanager "Hotspot Manager - portails captifs" ON \
        dnsprotect     "DNS Protect - filtrage DNS" OFF \
        studio         "STUDIO - contenus et campagnes" OFF)"
    for name in $(tr -d '"' <<< "$choices"); do
        install_product "$name"
    done
}

# ---------------------------------------------------------------- Agent d'inventaire

# Jeton d'enrôlement de l'agent : variable UP_ENROLL_TOKEN, ou embarqué dans l'ISO (/etc/up/registry.env, root 600).
# Il ne doit jamais être écrit dans ce dépôt public.
agent_enroll_token()
{
    if [[ -n "${UP_ENROLL_TOKEN:-}" ]]; then
        printf '%s' "$UP_ENROLL_TOKEN"
    elif [[ -r "${REGISTRY_ENV_FILE:-/etc/up/registry.env}" ]]; then
        (
            UP_ENROLL_TOKEN=""
            # shellcheck disable=SC1090
            source "${REGISTRY_ENV_FILE:-/etc/up/registry.env}"
            printf '%s' "$UP_ENROLL_TOKEN"
        )
    fi
}

# Agent d'inventaire (template « up-agent ») : un agent par nœud, qui envoie toutes les 6 h la configuration
# technique du serveur à la console du support Adipsys. Installé d'office ; seul le nom du client est demandé.
step_agent()
{
    local tpl token hint env_json
    if stack_exists up-agent; then
        log "Agent d'inventaire déjà déployé"
        return 0
    fi
    if ! tpl="$(template_json up-agent)"; then
        log "Template up-agent absent de ${TEMPLATES} : agent non installé"
        return 0
    fi

    token="$(agent_enroll_token)"
    if [[ -z "$token" ]]; then
        token="$(ask_or_quit ask_input "Agent d'inventaire Adipsys : jeton d'enrôlement (fourni par le support Adipsys).\n\nLaisser vide pour ne pas installer l'agent maintenant (« up-setup agent » plus tard)." "")"
        if [[ -z "$token" ]]; then
            report "⚠ Agent d'inventaire non installé (pas de jeton d'enrôlement) : « up-setup agent » pour l'installer."
            log "Agent d'inventaire non installé : pas de jeton"
            return 0
        fi
    fi
    hint="$(ask_or_quit ask_input "Agent d'inventaire Adipsys : nom du client (facultatif).\n\nIl aide le support Adipsys à reconnaître ce serveur." "${UP_CUSTOMER_HINT:-}")"

    # Valeurs par défaut du template (registre interne éventuel), sans les champs fournis ici ; le proxy est
    # ajouté par with_proxy_env.
    env_json="$(jq --arg reg "$ADIPSYS_IMAGES" '[.env[]?
        | select(.name | IN("HTTPS_PROXY", "UP_ENROLL_TOKEN", "UP_CUSTOMER_HINT") | not)
        | {name: .name, value: ((.default // "") | if startswith("registry.adipsys.com") then sub("^registry.adipsys.com"; $reg) else . end)}]' <<< "$tpl")"
    env_json="$(jq --arg t "$token" --arg h "$hint" \
        '. + [{name: "UP_ENROLL_TOKEN", value: $t}, {name: "UP_CUSTOMER_HINT", value: $h}]' <<< "$env_json")"
    env_json="$(with_proxy_env "$env_json" "$(stack_file_of "$tpl")")"

    clear 2>/dev/null || true
    echo "Déploiement de l'agent d'inventaire..."
    deploy_stack up-agent "$(stack_file_of "$tpl")" "$env_json"
    log "Stack up-agent déployée"
    WAIT_FAILURE=""
    if wait_stack up-agent; then
        report "Agent d'inventaire installé (stack up-agent) : rapport toutes les 6 h vers ${UP_CONSOLE_URL}."
    else
        report "⚠ Agent d'inventaire : ${WAIT_FAILURE}"
    fi
}

# ---------------------------------------------------------------- 6. Récapitulatif

ports_for() {
    case "$1" in
        hotspotmanager) echo "80/tcp, 443/tcp (portail, admin) ; 1812/udp, 1813/udp (Radius, depuis le contrôleur) ; 3799/udp (CoA) ; 514/udp (logs légaux)" ;;
        dnsprotect)     echo "80/tcp, 443/tcp (admin, page de blocage) ; 53/udp (DNS)" ;;
        studio)         echo "80/tcp, 443/tcp (admin, campagnes)" ;;
        rsyslog)        echo "514/udp (logs)" ;;
    esac
}

step_summary()
{
    local entry stack name url text
    {
        echo "Adipsys UP! - récapitulatif d'installation ($(date '+%d/%m/%Y %H:%M'))"
        echo "Serveur : $(hostname) - IP $(primary_ip)"
        [[ -n "$UP_HTTP_PROXY" ]] && echo "Proxy : ${UP_HTTP_PROXY} (sans proxy : ${UP_NO_PROXY})"
        [[ -n "$UP_DOCKERHUB_MIRROR" ]] && echo "Miroir Docker Hub : ${UP_DOCKERHUB_MIRROR}"
        [[ -n "$UP_ADIPSYS_REGISTRY" ]] && echo "Registre Adipsys interne : ${UP_ADIPSYS_REGISTRY}"
        [[ -f /etc/up-release ]] && grep -E '^UP_(ISO_VERSION|INSTALL_DATE)=' /etc/up-release
        echo
        printf '%s\n' ${REPORT_LINES[@]+"${REPORT_LINES[@]}"}
        echo
        for entry in ${INSTALLED[@]+"${INSTALLED[@]}"}; do
            IFS='|' read -r stack name url <<< "$entry"
            echo "== ${stack} (${name})"
            [[ -n "$url" ]] && echo "   Administration : https://${url}"
            echo "   Ports entrants à ouvrir : $(ports_for "$name")"
            if [[ "$name" == "hotspotmanager" ]]; then
                echo "   À faire : se connecter avec le compte superadmin fourni par Adipsys, saisir la clé de licence"
                echo "             (depuis le nom DNS définitif), changer le mot de passe, configurer le SMTP."
            fi
        done
        echo
        echo "Flux sortants nécessaires : 443/tcp vers licences.adipsys.com, ${REGISTRY}, Docker Hub, GitHub,"
        echo "${UP_CONSOLE_URL#https://} (agent d'inventaire) ;"
        echo "80+443/tcp vers *.debian.org ; 123/udp (NTP)."
        echo "Accès du support Adipsys (178.33.43.243) : 22/tcp et 9443/tcp, plus les ports applicatifs."
        echo
        echo "Mots de passe générés : ${SECRETS_FILE} (root uniquement)."
        echo "Mises à jour : up-update.sh -l, puis up-update.sh -s <stack> -v <version>."
    } > "$REPORT_FILE"
    chmod 600 "$REPORT_FILE"

    text="$(cat "$REPORT_FILE")"
    ui --scrolltext --msgbox "${text}\n\n(Ce récapitulatif est enregistré dans ${REPORT_FILE})" 28 90 || true
    clear 2>/dev/null || true
    cat "$REPORT_FILE"
}

# ---------------------------------------------------------------- Mise à jour des outils

# Met à jour le clone local (script, templates, stacks) puis relance le script s'il a changé :
# l'installation utilise toujours la dernière version publiée, cohérente entre script et stacks.
self_update()
{
    local before after
    [[ -z "${UP_SETUP_UPDATED:-}" && -d "${REPO_DIR}/.git" ]] || return 0
    before="$(git -C "$REPO_DIR" rev-parse HEAD)"
    echo "Mise à jour des outils Adipsys (${REPO_DIR})..."
    if ! git -C "$REPO_DIR" pull --ff-only --quiet 2>>"$LOG_FILE"; then
        log "git pull impossible, version locale ${before} utilisée"
        echo "Avertissement : mise à jour impossible (accès GitHub ou modifications locales), version locale utilisée."
        sleep 3
        return 0
    fi
    after="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [[ "$before" != "$after" ]]; then
        log "Outils mis à jour : ${before} → ${after}, relance"
        export UP_SETUP_UPDATED=1
        exec bash "$(readlink -f "$0")" "$@"
    fi
    log "Outils à jour (${after})"
}

# ---------------------------------------------------------------- Main

main()
{
    [[ "$(id -u)" -eq 0 ]] || { echo "À lancer en root."; exit 1; }
    for cmd in whiptail curl jq docker git; do
        command -v "$cmd" > /dev/null || { echo "Commande manquante : $cmd (apt-get install -y $cmd)"; exit 1; }
    done
    self_update "$@"
    [[ -f "$TEMPLATES" ]] || { echo "Templates introuvables : $TEMPLATES"; exit 1; }
    log "=== Démarrage de up-setup ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))"

    msg "Bienvenue dans l'installation d'Adipsys UP!\n\nCet assistant va :\n  1. vérifier le serveur et ses accès Internet ;\n  2. configurer Portainer et le registre Adipsys ;\n  3. installer Traefik, les produits choisis et l'agent d'inventaire Adipsys ;\n  4. afficher un récapitulatif (adresses, mots de passe, ports à ouvrir).\n\nMunissez-vous des identifiants du registre Adipsys et de vos noms de domaine.\nVous pouvez l'interrompre et le relancer à tout moment (commande « up-setup »)." 20

    step_checks
    step_portainer
    load_environment
    step_registry
    step_traefik
    step_products
    step_agent
    step_summary
    touch /var/lib/up/setup.done 2>/dev/null || true
    log "=== Fin de up-setup"
}

# « up-setup agent » : installe seulement l'agent d'inventaire (serveurs déjà configurés).
main_agent()
{
    [[ "$(id -u)" -eq 0 ]] || { echo "À lancer en root."; exit 1; }
    for cmd in whiptail curl jq docker git; do
        command -v "$cmd" > /dev/null || { echo "Commande manquante : $cmd (apt-get install -y $cmd)"; exit 1; }
    done
    self_update "$@"
    [[ -f "$TEMPLATES" ]] || { echo "Templates introuvables : $TEMPLATES"; exit 1; }
    log "=== up-setup agent ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    check_url "$UP_CONSOLE_URL" \
        || msg "Avertissement : ${UP_CONSOLE_URL} injoignable depuis ce serveur${UP_HTTP_PROXY:+ (proxy ${UP_HTTP_PROXY})}.\nL'agent sera installé mais ne pourra pas envoyer ses rapports tant que le flux 443/tcp n'est pas ouvert." 12
    step_portainer
    load_environment
    step_registry
    if stack_exists up-agent; then
        msg "L'agent d'inventaire est déjà installé (stack up-agent dans Portainer)." 8
    else
        step_agent
        msg "$(printf '%s\n' ${REPORT_LINES[@]+"${REPORT_LINES[@]}"})" 12
    fi
    clear 2>/dev/null || true
    printf '%s\n' ${REPORT_LINES[@]+"${REPORT_LINES[@]}"}
    log "=== Fin de up-setup agent"
}

trap 'log "Erreur ligne $LINENO : $BASH_COMMAND"; echo "Erreur inattendue (ligne $LINENO). Voir $LOG_FILE."' ERR

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "agent" ]]; then
        main_agent "$@"
    else
        main "$@"
    fi
fi
