#!/bin/bash
# Met à jour le conteneur Portainer vers la dernière image portainer/portainer-ce.
#
# - Reprend les options du conteneur actuel (arguments --logo/--templates et variables de proxy).
# - Conserve les données (volume portainer_data).
# - Garde l'ancien conteneur jusqu'à ce que le nouveau tourne ; en cas d'échec, l'ancien est relancé.
#
# Usage : portainer-update.sh [-f] [-i IMAGE]
#   -f        recrée le conteneur même si l'image n'a pas changé
#   -i IMAGE  image à utiliser (défaut : portainer/portainer-ce:latest)

NAME="portainer"
IMAGE="portainer/portainer-ce:latest"
FORCE=0
LOG="/var/log/portainer_update.log"

while getopts "fi:" option; do
    case "$option" in
        f) FORCE=1 ;;
        i) IMAGE="$OPTARG" ;;
        *) echo "Usage: $0 [-f] [-i IMAGE]"; exit 1 ;;
    esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }

if ! docker inspect "$NAME" > /dev/null 2>&1; then
    log "Conteneur '$NAME' introuvable : rien à mettre à jour."
    exit 1
fi

OLD_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$NAME")

# Options du conteneur actuel à reprendre.
ARGS=()
while IFS= read -r arg; do
    [ -n "$arg" ] && ARGS+=("$arg")
done < <(docker inspect -f '{{range .Args}}{{println .}}{{end}}' "$NAME")
ENV_OPTS=()
while IFS= read -r var; do
    case "$var" in
        HTTP_PROXY=*|HTTPS_PROXY=*|NO_PROXY=*|http_proxy=*|https_proxy=*|no_proxy=*) ENV_OPTS+=(-e "$var") ;;
    esac
done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME")

log "Téléchargement de $IMAGE ..."
if ! docker pull "$IMAGE" > /dev/null; then
    log "Échec du téléchargement de $IMAGE."
    exit 1
fi
NEW_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")

if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ] && [ "$FORCE" -eq 0 ]; then
    log "Portainer est déjà à jour."
    exit 0
fi

log "Arrêt de l'ancien conteneur (conservé sous le nom $NAME-old)."
docker rm -f "$NAME-old" > /dev/null 2>&1
docker stop "$NAME" > /dev/null
docker rename "$NAME" "$NAME-old"
docker update --restart=no "$NAME-old" > /dev/null

log "Démarrage du nouveau conteneur."
docker run -d -p 8000:8000 -p 9443:9443 --name="$NAME" --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    "${ENV_OPTS[@]}" \
    "$IMAGE" "${ARGS[@]}" > /dev/null

sleep 10
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]; then
    docker rm "$NAME-old" > /dev/null
    log "Portainer mis à jour : $(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$NAME" 2>/dev/null)"
    exit 0
fi

log "Le nouveau conteneur ne démarre pas, retour à l'ancien. Logs :"
docker logs --tail 20 "$NAME" 2>&1 | tee -a "$LOG"
docker rm -f "$NAME" > /dev/null 2>&1
docker rename "$NAME-old" "$NAME"
docker update --restart=always "$NAME" > /dev/null
docker start "$NAME" > /dev/null
exit 1
