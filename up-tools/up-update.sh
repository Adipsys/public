#!/usr/bin/env bash
# Mise à jour d'un produit Adipsys (stack Portainer) avec sauvegarde préalable.
#
#   up-update.sh -l                                   liste les stacks et leur PRODUCT_VERSION
#   up-update.sh -s STACK -v VERSION [options]        met à jour la stack
#   up-update.sh -s STACK --rollback DOSSIER [-y]     restaure la sauvegarde et l'ancienne version
#
# Options :
#   -t SECONDES   délai d'attente de la mise à jour (défaut 900)
#   -y            pas de confirmation interactive
#   --no-http     ne pas tester la page de connexion
#
# Étapes d'une mise à jour :
#   1. vérifications (stack saine, place disque) ;
#   2. sauvegarde de la base (mysqldump) et des volumes de données dans /backups/pre-update/ ;
#   3. changement de PRODUCT_VERSION par l'API Portainer (la stack reste gérée par Portainer) ;
#   4. attente que tous les services soient à jour et que la page de connexion réponde.
# Les migrations de base ne sont pas réversibles : en cas d'échec, le retour arrière restaure
# la sauvegarde (il efface les données écrites depuis la mise à jour) et se lance à la main.
#
# Configuration : /root/.up-update.conf (droits 600)
#   PORTAINER_API_KEY="ptr_..."          Portainer → My account → Access tokens
#   PORTAINER_URL="https://127.0.0.1:9443"   (optionnel)
#
# Dépendances : docker, curl, jq, gzip, tar.

set -euo pipefail
umask 077

readonly CONF_FILE="${UP_UPDATE_CONF:-/root/.up-update.conf}"
readonly BACKUP_ROOT="${UP_UPDATE_BACKUP_ROOT:-/backups/pre-update}"
readonly LOG_FILE="${UP_UPDATE_LOG:-/var/log/up-update.log}"
readonly LOCK_FILE="${UP_UPDATE_LOCK:-/run/up-update.lock}"
readonly RETENTION="${UP_UPDATE_RETENTION:-3}"
readonly POLL="${UP_UPDATE_POLL:-10}"
# Volumes non sauvegardés : la base (sauvegardée par mysqldump), les logs, les index Elasticsearch.
readonly VOLUME_EXCLUDE="${UP_UPDATE_VOLUME_EXCLUDE:-db_vol|logs|dashboard}"
readonly DB_SERVICE_PATTERN='_(hm-db-seed|hm-db|dnsp-db|studio-db)\.'

STACK=""
VERSION=""
ROLLBACK_DIR=""
TIMEOUT=900
ASSUME_YES=0
HTTP_CHECK=1
LIST=0

usage()
{
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

log()
{
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${STACK:-up-update}] $*"
    echo "$line"
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

die()
{
    log "ERREUR : $*"
    exit 1
}

confirm()
{
    local answer

    (( ASSUME_YES )) && return 0
    read -r -p "$1 [o/N] " answer
    [[ "$answer" =~ ^[oOyY] ]]
}

# ---------------------------------------------------------------- Portainer API

load_config()
{
    [[ -f "$CONF_FILE" ]] || die "configuration absente : $CONF_FILE (voir l'en-tête du script)"
    if [[ "$(stat -c '%a' "$CONF_FILE" 2>/dev/null || echo 600)" != "600" ]]; then
        die "$CONF_FILE doit avoir les droits 600"
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    : "${PORTAINER_URL:=https://127.0.0.1:9443}"
    [[ -n "${PORTAINER_API_KEY:-}" ]] || die "PORTAINER_API_KEY absent de $CONF_FILE"
}

api()
{
    local method="$1" path="$2"
    shift 2
    curl --fail --silent --show-error --insecure \
        --header "X-API-Key: ${PORTAINER_API_KEY}" \
        --request "$method" "$@" \
        "${PORTAINER_URL%/}/api${path}"
}

stack_json()
{
    api GET /stacks | jq -e --arg name "$STACK" '[.[] | select(.Name == $name)] | first // empty' \
        || die "stack '$STACK' introuvable dans Portainer"
}

stack_env_value()
{
    jq -r --arg name "$2" '(.Env // [])[] | select(.name == $name) | .value' <<< "$1"
}

update_stack_version()
{
    local stack="$1" new_version="$2"
    local stack_id endpoint_id stack_file payload

    stack_id="$(jq -r '.Id' <<< "$stack")"
    endpoint_id="$(jq -r '.EndpointId' <<< "$stack")"
    stack_file="$(api GET "/stacks/${stack_id}/file" | jq -r '.StackFileContent')"
    [[ -n "$stack_file" && "$stack_file" != "null" ]] || die "impossible de lire le fichier de la stack"

    payload="$(jq -n \
        --arg file "$stack_file" \
        --arg version "$new_version" \
        --argjson env "$(jq '.Env // []' <<< "$stack")" \
        '{
            stackFileContent: $file,
            env: ( if any($env[]; .name == "PRODUCT_VERSION")
                   then [ $env[] | if .name == "PRODUCT_VERSION" then .value = $version else . end ]
                   else $env + [ { name: "PRODUCT_VERSION", value: $version } ] end ),
            prune: false,
            pullImage: true
        }')"

    api PUT "/stacks/${stack_id}?endpointId=${endpoint_id}" \
        --header 'Content-Type: application/json' \
        --data "$payload" > /dev/null
}

# ---------------------------------------------------------------- Docker

stack_services()
{
    docker stack services "$STACK" --format '{{.Name}}' 2>/dev/null | sort
}

db_container()
{
    docker ps --filter "label=com.docker.stack.namespace=${STACK}" --format '{{.Names}}' \
        | grep -E "$DB_SERVICE_PATTERN" | head -n 1 || true
}

data_volumes()
{
    docker volume ls --filter "label=com.docker.stack.namespace=${STACK}" --format '{{.Name}}' \
        | grep -vE "$VOLUME_EXCLUDE" || true
}

# Affiche "ok", "wait" ou "fail:<raison>" pour l'ensemble des services de la stack.
# $1 : début de la mise à jour (epoch). Les états Swarm plus anciens sont ignorés ;
# sans $1 (vérification préalable), seul un état bloquant (en cours, en pause) est pris en compte.
stack_state()
{
    local since="${1:-}" service mode desired status state started running

    for service in $(stack_services); do
        mode="$(docker service inspect -f '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{else}}global{{end}}' "$service")"
        status="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}|{{if .UpdateStatus.StartedAt}}{{.UpdateStatus.StartedAt.Unix}}{{end}}{{end}}' "$service")"
        state="${status%%|*}"
        started="${status#*|}"
        if [[ -n "$since" ]]; then
            if [[ -z "$started" ]] || (( started < since )); then
                state=""
            fi
            case "$state" in
                paused|rollback_started|rollback_paused|rollback_completed)
                    echo "fail:${service} (mise à jour Swarm : ${state})"; return ;;
                updating)
                    echo "wait"; return ;;
            esac
        else
            case "$state" in
                updating|paused|rollback_started|rollback_paused)
                    echo "fail:${service} (mise à jour Swarm : ${state})"; return ;;
            esac
        fi
        running="$(docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true)"
        if [[ "$mode" == "global" ]]; then
            desired=1
        else
            desired="$mode"
        fi
        if (( running < desired )); then
            echo "wait"; return
        fi
    done
    echo "ok"
}

# Nom d'hôte de l'interface d'administration, déduit des variables de la stack.
admin_host()
{
    local stack="$1" hm_name hm_suffix studio dnsp

    hm_name="$(stack_env_value "$stack" HM_SERVER_NAME)"
    hm_suffix="$(stack_env_value "$stack" HM_URL_SUFFIX)"
    studio="$(stack_env_value "$stack" STUDIO_NAME)"
    dnsp="$(stack_env_value "$stack" SERVER_NAME)"

    if [[ -n "$hm_name" && -n "$hm_suffix" ]]; then
        echo "${hm_name}-admin.${hm_suffix}"
    elif [[ -n "$studio" ]]; then
        echo "$studio"
    elif [[ -n "$dnsp" ]]; then
        echo "$dnsp"
    fi
}

http_code()
{
    curl --silent --insecure --output /dev/null --max-time 10 --write-out '%{http_code}' \
        --resolve "$1:443:127.0.0.1" "https://$1/" || true
}

wait_for_stack()
{
    local stack="$1" new_version="$2" since="$3"
    local deadline state host code=""

    deadline=$(( $(date +%s) + TIMEOUT ))
    host=""
    (( HTTP_CHECK )) && host="$(admin_host "$stack")"
    if (( HTTP_CHECK )) && [[ -z "$host" ]]; then
        log "Nom d'hôte d'administration inconnu : test de la page de connexion ignoré"
    fi

    sleep "$POLL"
    while (( $(date +%s) < deadline )); do
        state="$(stack_state "$since")"
        case "$state" in
            fail:*) log "Échec : ${state#fail:}"; return 1 ;;
            ok)
                if [[ -z "$host" ]]; then
                    return 0
                fi
                code="$(http_code "$host")"
                if [[ "$code" =~ ^[23] ]]; then
                    log "Page de connexion https://${host}/ : HTTP ${code}"
                    return 0
                fi
                ;;
        esac
        sleep "$POLL"
    done
    log "Délai dépassé (${TIMEOUT}s). Dernier état : ${state:-?}${host:+, page de connexion HTTP ${code:-?}}"
    return 1
}

# ---------------------------------------------------------------- Sauvegarde / restauration

backup()
{
    local dir="$1" db volume mountpoint

    mkdir -p "$dir"

    db="$(db_container)"
    [[ -n "$db" ]] || die "aucun conteneur de base de la stack sur ce serveur (en HA, lancer sur le nœud principal)"

    log "Sauvegarde de la base (${db}) ..."
    docker exec "$db" sh -c 'exec mysqldump -u root --password="$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --routines --events' \
        | gzip -6 > "${dir}/database.sql.gz"
    gzip -t "${dir}/database.sql.gz"
    [[ $(gzip -dc "${dir}/database.sql.gz" | head -c 4096 | wc -c) -gt 0 ]] || die "sauvegarde de la base vide"
    log "Base sauvegardée : $(du -h "${dir}/database.sql.gz" | cut -f1)"

    for volume in $(data_volumes); do
        mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume")"
        log "Sauvegarde du volume ${volume} ..."
        tar -czf "${dir}/volume-${volume}.tar.gz" -C "$mountpoint" .
    done
}

restore()
{
    local dir="$1" db archive volume mountpoint

    db="$(db_container)"
    [[ -n "$db" ]] || die "aucun conteneur de base de la stack sur ce serveur"

    log "Restauration de la base dans ${db} ..."
    gzip -dc "${dir}/database.sql.gz" \
        | docker exec -i "$db" sh -c 'exec mysql -u root --password="$MYSQL_ROOT_PASSWORD"'

    for archive in "$dir"/volume-*.tar.gz; do
        [[ -e "$archive" ]] || continue
        volume="$(basename "$archive" .tar.gz)"
        volume="${volume#volume-}"
        mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume")"
        log "Restauration du volume ${volume} ..."
        find "$mountpoint" -mindepth 1 -delete
        tar -xzf "$archive" -C "$mountpoint"
    done
}

purge_old_backups()
{
    local old

    ls -1dt "${BACKUP_ROOT}/${STACK}-"*/ 2>/dev/null | tail -n +"$(( RETENTION + 1 ))" | while read -r old; do
        rm -rf "$old"
        log "Ancienne sauvegarde supprimée : ${old}"
    done
}

# ---------------------------------------------------------------- Actions

do_list()
{
    load_config
    api GET /stacks | jq -r '.[] | [.Name, ((.Env // [])[] | select(.name == "PRODUCT_VERSION") | .value) // "-"] | @tsv' \
        | sort | awk -F'\t' '{ printf "%-30s %s\n", $1, $2 }'
}

do_update()
{
    local stack current dir state free needed since

    load_config
    stack="$(stack_json)"
    current="$(stack_env_value "$stack" PRODUCT_VERSION)"
    [[ -n "$current" ]] || die "la stack n'a pas de variable PRODUCT_VERSION"
    [[ "$current" != "$VERSION" ]] || die "la stack est déjà en version ${VERSION}"

    state="$(stack_state)"
    [[ "$state" == "ok" ]] || die "la stack n'est pas saine avant la mise à jour (${state}) : corriger d'abord"

    mkdir -p "$BACKUP_ROOT"
    free="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
    needed=1048576   # 1 Go minimum
    (( free > needed )) || die "moins de 1 Go libre dans ${BACKUP_ROOT}"

    log "Mise à jour ${current} → ${VERSION}"
    echo
    echo "  Stack     : ${STACK}"
    echo "  Version   : ${current} → ${VERSION}"
    echo "  Sauvegarde: ${BACKUP_ROOT}/${STACK}-${current}-<date>/"
    echo "  Les migrations de base ne sont pas réversibles. Un snapshot de la VM est recommandé."
    echo
    confirm "Lancer la mise à jour ?" || die "annulé"

    dir="${BACKUP_ROOT}/${STACK}-${current}-$(date +%Y%m%d-%H%M%S)"
    backup "$dir"
    jq '{Id, Name, EndpointId, Env}' <<< "$stack" > "${dir}/stack.json"
    printf 'STACK=%s\nFROM_VERSION=%s\nTO_VERSION=%s\nDATE=%s\n' \
        "$STACK" "$current" "$VERSION" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "${dir}/update.env"
    log "Sauvegarde terminée : ${dir}"

    log "Mise à jour de la stack par l'API Portainer ..."
    since="$(date +%s)"
    update_stack_version "$stack" "$VERSION"

    if wait_for_stack "$stack" "$VERSION" "$since"; then
        log "Mise à jour réussie : ${STACK} en version ${VERSION}"
        purge_old_backups
        return 0
    fi

    log "La mise à jour n'a pas abouti. État des services :"
    docker stack ps "$STACK" --no-trunc --filter desired-state=running 2>&1 | tee -a "$LOG_FILE" || true
    echo
    echo "Pour revenir à la version ${current} (restaure la base et les volumes sauvegardés) :"
    echo "  $0 -s ${STACK} --rollback ${dir}"
    exit 2
}

do_rollback()
{
    local stack from_version service replicas since entry
    local saved_replicas=()

    load_config
    [[ -f "${ROLLBACK_DIR}/update.env" && -f "${ROLLBACK_DIR}/database.sql.gz" ]] \
        || die "${ROLLBACK_DIR} n'est pas une sauvegarde up-update valide"
    from_version="$(sed -n 's/^FROM_VERSION=//p' "${ROLLBACK_DIR}/update.env")"
    [[ "$(sed -n 's/^STACK=//p' "${ROLLBACK_DIR}/update.env")" == "$STACK" ]] \
        || die "cette sauvegarde n'appartient pas à la stack ${STACK}"
    stack="$(stack_json)"

    echo
    echo "  Stack   : ${STACK}"
    echo "  Retour  : version ${from_version}"
    echo "  Source  : ${ROLLBACK_DIR}"
    echo "  ATTENTION : les données écrites depuis la sauvegarde seront PERDUES."
    echo
    confirm "Restaurer la sauvegarde ?" || die "annulé"

    log "Arrêt des services applicatifs ..."
    for service in $(stack_services); do
        [[ "$service" =~ _(hm-db-seed|hm-db|dnsp-db|studio-db)$ ]] && continue
        replicas="$(docker service inspect -f '{{if .Spec.Mode.Replicated}}{{.Spec.Mode.Replicated.Replicas}}{{end}}' "$service")"
        [[ -n "$replicas" ]] || continue
        saved_replicas+=("${service}=${replicas}")
        docker service scale --detach "${service}=0" > /dev/null
    done
    sleep "$POLL"

    restore "$ROLLBACK_DIR"

    log "Retour à la version ${from_version} par l'API Portainer ..."
    since="$(date +%s)"
    update_stack_version "$stack" "$from_version"

    # Remet le nombre de réplicas d'origine aux services restés à 0 après le redéploiement.
    for entry in ${saved_replicas[@]+"${saved_replicas[@]}"}; do
        service="${entry%=*}"
        replicas="$(docker service inspect -f '{{.Spec.Mode.Replicated.Replicas}}' "$service" 2>/dev/null || echo "")"
        if [[ "$replicas" == "0" ]]; then
            docker service scale --detach "$entry" > /dev/null
        fi
    done

    if wait_for_stack "$stack" "$from_version" "$since"; then
        log "Retour arrière terminé : ${STACK} en version ${from_version}"
        return 0
    fi
    die "la stack ne redémarre pas correctement après le retour arrière : intervention manuelle nécessaire"
}

# ---------------------------------------------------------------- Main

while (( $# )); do
    case "$1" in
        -l) LIST=1 ;;
        -s) STACK="${2:-}"; shift ;;
        -v) VERSION="${2:-}"; shift ;;
        -t) TIMEOUT="${2:-}"; shift ;;
        -y) ASSUME_YES=1 ;;
        --no-http) HTTP_CHECK=0 ;;
        --rollback) ROLLBACK_DIR="${2:-}"; shift ;;
        -h|--help) usage ;;
        *) echo "Option inconnue : $1"; usage ;;
    esac
    shift
done

for cmd in docker curl jq gzip tar; do
    command -v "$cmd" > /dev/null || { echo "Commande manquante : $cmd (apt-get install -y $cmd)"; exit 1; }
done

if (( LIST )); then
    do_list
    exit 0
fi

[[ -n "$STACK" ]] || usage
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || usage

exec 9> "$LOCK_FILE"
flock -n 9 || { echo "Une autre exécution de up-update est en cours."; exit 1; }

if [[ -n "$ROLLBACK_DIR" ]]; then
    do_rollback
elif [[ -n "$VERSION" ]]; then
    do_update
else
    usage
fi
