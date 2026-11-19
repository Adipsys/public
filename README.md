# Adipsys – templates Portainer et outils UP

Ce dépôt contient tout ce que les serveurs **UP** (installés depuis l'ISO Adipsys) récupèrent depuis Internet :

- les **templates d'applications Portainer** des produits Adipsys ;
- les **stacks Docker Swarm** déployées par ces templates ;
- les **outils d'exploitation** (sauvegardes, restauration…) installés sur chaque serveur.

> ⚠️ Ce dépôt est **public** : n'y mettez jamais de mot de passe, de clé ou de donnée client.

## Documentation utilisateur

| Guide | Pour qui |
|---|---|
| [Démarrage rapide](docs/demarrage-rapide.md) | Un serveur, installé avec l'ISO, accès direct à Internet : le cas courant, en 3 étapes. |
| [Guide d'installation et de mise à jour](docs/guide-installation.md) | Tous les cas : Debian existante, proxy, certificats, mises à jour, sauvegardes, dépannage. |

English: [Quick start](docs/en/quick-start.md) · [Installation and update guide](docs/en/installation-guide.md)

La suite de ce README s'adresse aux équipes Adipsys (fonctionnement technique du dépôt).

## Contenu

| Chemin | Rôle |
|---|---|
| `portainer-templates/templates.json` | Liste des templates affichée dans Portainer (*App Templates*). |
| `stacks/traefik.yml` | Reverse proxy commun, crée le réseau `traefik_default`. |
| `stacks/hotspotmanager.yml` | Hotspot Manager (serveur seul). |
| `stacks/hotspotmanager-ha.yml` | Hotspot Manager en haute disponibilité (cluster de 3 managers). |
| `stacks/dnsprotect.yml` | DNS Protect. |
| `stacks/studio.yml` | STUDIO. |
| `stacks/rsyslog.yml` | rSyslog autonome. |
| `stacks/up-agent.yml` | Agent d'inventaire UP (un par nœud), qui remonte la configuration technique à la console du support. |
| `bootstrap/up-bootstrap.sh` | Préparation d'un serveur UP (Docker, Swarm, Portainer, outils, sauvegardes), utilisée par l'ISO et sur une Debian 13 existante. |
| `up-tools/` | Scripts d'exploitation clonés sur chaque serveur dans `/usr/local/bin/public/up-tools/`. |

URL des templates à renseigner dans Portainer (*Settings → App Templates*) :

```
https://raw.githubusercontent.com/Adipsys/public/refs/heads/main/portainer-templates/templates.json
```

Les serveurs installés avec l'ISO actuelle sont déjà configurés avec cette URL.

## Préparer un serveur UP

Deux possibilités, qui aboutissent au même serveur :

- **ISO Adipsys** (dépôt `simple-cdd`) : installation complète de Debian puis de la plateforme.
- **Debian 13 déjà installée** (serveur du client, VM cloud…), sans environnement graphique, avec accès à Internet :

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Adipsys/public/main/bootstrap/up-bootstrap.sh -o up-bootstrap.sh
  sudo bash up-bootstrap.sh
  ```

  Le script installe les paquets de base et Docker (dépôt officiel), configure les réseaux Docker, les mises à jour
  de sécurité automatiques, l'accès du support, les outils `up-tools` et les sauvegardes, puis crée le Swarm et Portainer.
  Il refuse un autre système que Debian 13 (option `--force`) et une installation Docker existante hors dépôt officiel.
  Il peut être relancé sans risque. Journal : `/var/log/up-bootstrap.log`.

### Réseau sans accès direct à Internet (proxy, miroirs internes)

La licence impose un accès au serveur de licences ; il peut passer par un **proxy**. Les téléchargements peuvent
aussi passer par des **miroirs internes** du client :

```bash
sudo bash up-bootstrap.sh --proxy http://proxy.client.fr:3128 \
    --no-proxy "intra.client.fr,10.0.0.0/8" \
    --dockerhub-mirror https://nexus.client.fr:8443 \
    --adipsys-registry harbor.client.fr/adipsys
```

| Option | Effet |
|---|---|
| `--proxy URL` | Proxy pour apt, git, curl, Docker (téléchargement des images), Portainer et les produits (licences, API externes). `none` le retire. Avec l'ISO, le proxy saisi dans l'installateur Debian (« Mandataire HTTP ») est repris automatiquement. |
| `--no-proxy LISTE` | Destinations jointes sans proxy (`localhost` et `127.0.0.1` toujours inclus ; les noms des services internes sont ajoutés aux stacks). |
| `--dockerhub-mirror URL` | Miroir interne de Docker Hub (Portainer, Traefik, memcached…). |
| `--adipsys-registry CHEMIN` | Registre interne qui réplique `registry.adipsys.com` (ex. projet proxy-cache Harbor) : utilisé par `up-setup` pour les images des produits. |

Les réglages sont enregistrés dans `/etc/up/up.conf` (relancer `up-bootstrap.sh` pour les modifier) et repris par
`up-firstboot`, `up-setup` et `up-update.sh`. Flux à autoriser sur le proxy : voir la documentation pare-feu
(licences, registre Adipsys, Docker Hub, GitHub, Debian).

## Installer les produits : assistant `up-setup` (recommandé)

Sur le serveur, en root :

```bash
up-setup
```

L'assistant (en mode texte, relançable à tout moment) :

1. vérifie les ressources (CPU, RAM, disque) et les **accès Internet** nécessaires (licences, registre Adipsys,
   Docker Hub, GitHub, Debian, NTP, console d'inventaire Adipsys) et signale ce qui est bloqué ;
2. **crée le compte administrateur Portainer** (mot de passe généré) et une clé d'API (utilisée aussi par `up-update.sh`) ;
3. demande les **identifiants du registre Adipsys**, les vérifie et les enregistre dans Portainer ;
4. installe **Traefik** ;
5. installe les **produits choisis** : seules les informations utiles sont demandées (société, nom du serveur, domaine,
   e-mail), les mots de passe sont générés, les **noms DNS sont vérifiés**, certificats Let's Encrypt en option ;
6. installe l'**agent d'inventaire** (template `up-agent`) : il envoie toutes les heures la configuration technique du
   serveur à la console du support Adipsys (`up-console.adipsys.net`, HTTPS sortant). Jeton d'enrôlement embarqué
   dans l'ISO (`/etc/up/registry.env`) ou demandé ; seul le nom du client (facultatif) est demandé ;
7. affiche et enregistre un **récapitulatif** : adresses, ports à ouvrir pour les produits installés, étapes restantes
   (licence, SMTP…).

Sur un serveur déjà configuré, pour installer seulement l'agent d'inventaire :

```bash
up-setup agent
```

### Mise en conformité d'un serveur installé avant l'ISO (`up-setup tools`)

Les serveurs installés sans l'ISO récente n'ont ni les outils (`up-update`, `up-setup`) ni la clé d'API Portainer qui
sert aux montées de version. En root, sur un manager du cluster :

```bash
apt update && apt install -y git curl jq whiptail
git clone https://github.com/Adipsys/public.git /usr/local/bin/public
/usr/local/bin/public/up-tools/up-setup.sh tools
```

`up-setup tools` crée les commandes `up-update` et `up-setup` (liens dans `/usr/local/sbin`, comme l'ISO), puis la clé
d'API Portainer dans `/root/.up-update.conf` à partir du compte administrateur demandé. Le Portainer est le Portainer
local par défaut ; s'il ne répond pas (Portainer « séparé », sur une autre machine), son adresse est demandée et
enregistrée (`PORTAINER_URL`). Une clé existante qui fonctionne est conservée ; la commande peut être relancée sans
risque. Elle ne touche ni aux sauvegardes ni aux tâches planifiées. La console up-console (écran *Mises à jour*) indique,
pour chaque plateforme, si `up-update` est présent et les commandes à lancer sinon.

Fichiers créés (root uniquement) : `/root/up-secrets.env` (mots de passe), `/root/.up-update.conf` (clé d'API Portainer),
`/root/up-install-report.txt` (récapitulatif). Journal : `/var/log/up-setup.log`.

L'assistant déploie les mêmes stacks que les App Templates (définitions lues dans `portainer-templates/templates.json`).
Au démarrage, il met à jour les outils (`git pull` de `/usr/local/bin/public`) et se relance si une nouvelle version
est disponible ; sans accès à GitHub, il utilise la version locale.

## Installer un produit depuis Portainer (méthode manuelle)

1. **Installer d'abord le template `Traefik`.** Il crée le réseau `traefik_default` dont tous les produits ont besoin.
   Sans lui, le déploiement d'un produit échoue avec `network "traefik_default" is declared as external, but could not be found`.
2. Installer le produit (Hotspot Manager, DNS Protect, STUDIO…) depuis *App Templates* et remplir le formulaire.
3. Créer les enregistrements DNS correspondant aux noms saisis (ex. `wifi.domaine.fr`, `wifi-admin.domaine.fr`, `wifi-api.domaine.fr` pour Hotspot Manager).

### Certificats TLS

Deux possibilités, au choix pour chaque stack :

- **Certificat fourni** (par défaut) : déposer le certificat et la clé dans `/root/ssl_certificates/` (créé par l'ISO)
  et les déclarer dans `/root/traefik/traefik.yaml`. Exemple : [`up-tools/traefik.yaml`](up-tools/traefik.yaml).
- **Let's Encrypt automatique** : ajouter la variable **`TLS_RESOLVER=letsencrypt`** à la stack du produit puis *Update the stack*.
  Traefik obtient et renouvelle seul les certificats des noms du produit.
  Prérequis : les noms DNS pointent vers le serveur et le **port 80 est joignable depuis Internet** (validation HTTP).

Les interfaces d'administration sont redirigées de HTTP vers HTTPS ; le portail captif et l'API restent accessibles en HTTP.

## Mettre à jour un produit

Les images appliquent automatiquement les migrations de base au démarrage, **sans retour arrière possible** :
revenir à l'ancienne version impose de restaurer la base d'avant la mise à jour. Un snapshot de la VM reste recommandé.

### Méthode recommandée : `up-update.sh`

```bash
/usr/local/bin/public/up-tools/up-update.sh -l                          # stacks et versions
/usr/local/bin/public/up-tools/up-update.sh -s hotspotmanager -v 3.41.3 # mise à jour
```

Le script :

1. vérifie que la stack est saine et qu'il reste au moins 1 Go libre ;
2. sauvegarde la base (`mysqldump`) et les volumes de données (hors base, logs et index Elasticsearch)
   dans `/backups/pre-update/<stack>-<ancienne version>-<date>/` (3 dernières sauvegardes conservées par stack) ;
3. change `PRODUCT_VERSION` **par l'API Portainer** (la stack reste gérée normalement dans Portainer) ;
4. attend que tous les services soient à jour (15 min max, option `-t`) et que la page de connexion de l'administration
   réponde (option `--no-http` pour ne pas la tester).

En cas d'échec, ou d'erreurs dans les logs, il renvoie le client vers le support Adipsys, sans proposer le retour arrière. Le retour arrière, **réservé au support**, se lance à la main car il efface les données écrites depuis la mise à jour :

```bash
up-update.sh -s hotspotmanager --rollback /backups/pre-update/hotspotmanager-3.41.2-20261118-103000/
```

Elle arrête les services applicatifs, restaure la base et les volumes, puis remet l'ancienne version par l'API Portainer.

En HA, lancer le script sur le **nœud principal** (celui qui porte la base). Journal : `/var/log/up-update.log`.

**Configuration (une fois par serveur)** : le plus simple est `up-setup tools` (voir plus haut), qui crée la clé. À la main :
créer une clé d'API dans Portainer (*My account → Access tokens*), puis :

```bash
apt update && apt install -y jq   # déjà présent sur les serveurs installés avec une ISO récente
git -C /usr/local/bin/public pull
install -m 600 /dev/null /root/.up-update.conf
echo 'PORTAINER_API_KEY="ptr_xxxxxxxx"' >> /root/.up-update.conf
```

### Méthode manuelle

Dans Portainer, ouvrir la stack → onglet *Editor*, modifier **`PRODUCT_VERSION`** puis **Update the stack**,
après avoir sauvegardé la base (voir [Sauvegardes](#sauvegardes)).

### Version de la base de données

La version de l'image de base est **fixe** (définie par défaut dans la stack) et ne suit pas `PRODUCT_VERSION`.
Pour la changer exceptionnellement, ajouter manuellement la variable **`DB_VERSION`** dans les variables de la stack.

### Variables optionnelles (à ajouter manuellement)

Ces variables ne sont pas dans les formulaires ; elles sont vides par défaut et peuvent être ajoutées à la stack au besoin :

| Variable | Produits | Usage |
|---|---|---|
| `DB_VERSION` | HM, HM HA, DNS Protect | Version de l'image de base (voir ci-dessus). |
| `HOTSPOT_ALIAS1` | HM, HM HA | URL secondaire du portail. |
| `ADMIN_ALIAS1` | HM, HM HA | URL secondaire de l'interface d'administration. |
| `RSYSLOG_SERVER` | HM, HM HA, DNS Protect | Envoi des logs vers un autre serveur (ex. LOGview). |
| `RSYSLOG_ROTATE` | HM, HM HA, rSyslog | Rotation des logs rSyslog. |
| `RADIUS_COMMAND` | HM, HM HA | Commande de démarrage de radius (debug : `freeradius -XXX`). |
| `SERVER_ALIAS` | DNS Protect | URL secondaire de l'administration. |
| `TLS_RESOLVER` | HM, HM HA, DNS Protect, STUDIO | `letsencrypt` pour des certificats automatiques (voir [Certificats TLS](#certificats-tls)). |
| `TRAEFIK_VERSION` | Traefik | Tag de l'image Traefik (défaut `v3`). |

## Hotspot Manager HA

Prérequis : un cluster Swarm de **3 nœuds managers** et la stack Traefik déployée.

| Champ | Rôle |
|---|---|
| `HA_PRIMARY_NODE` | Hostname du nœud principal (`docker node ls`). Il porte `hm-db-seed`, `hm-web` (administration) et `hm-rsyslog`. |
| `HA_DB_REPLICAS` | Nombre de nœuds Galera secondaires (`hm-db`). |

Procédure d'initialisation du cluster Galera :

1. Installer avec **`HA_DB_REPLICAS=1`** : le cluster démarre à 2 nœuds (seed + 1).
2. Une fois le cluster synchronisé, passer **`HA_DB_REPLICAS=2`** dans les variables de la stack et faire *Update the stack* : le 3ᵉ nœud rejoint le cluster.
3. La valeur reste enregistrée dans la stack : les mises à jour suivantes conservent les 3 nœuds.

## Notes techniques

- **Adresse des nœuds Galera** (`NODE_ADDRESS=^10\.[02]`) : le conteneur de base choisit l'IP qu'il annonce parmi ses adresses.
  Le motif accepte les réseaux overlay en `10.0.x` (pool Swarm par défaut) et `10.200.x` (pool configuré par l'ISO),
  et exclut `docker0` (`10.100.x`) et `docker_gwbridge` (`10.101.x`).
- **Noms de routeurs Traefik** de Hotspot Manager : construits à partir de `OPERATOR` et `HM_SERVER_NAME`
  (`OPERATOR` doit donc être sans espace ni caractère spécial).
- Les templates lisent toujours les stacks sur la branche **`main`** : un fichier n'est disponible pour Portainer qu'une fois fusionné dans `main`.

## Sauvegardes

L'ISO installe ces tâches cron (dossiers dans `/backups/`) :

| Heure | Script | Contenu |
|---|---|---|
| 00:00 | `docker-engine-backup.sh -s /var/lib/docker/swarm -t /backups/docker-engine/ -d 30` | État du Swarm |
| 00:05 | `docker-volume-backup.sh -v portainer_data -t /backups/docker-volumes/ -d 30` | Données Portainer |
| 00:15 | `docker-db-backup.sh -c all -t /backups/docker-db/ -d 30` | Bases `hm-db`, `dnsp-db`, `studio-db` |

`-d 30` purge les sauvegardes de plus de 30 jours.
`docker-db-backup.sh` lit le mot de passe root dans le conteneur (`MYSQL_ROOT_PASSWORD`) ; l'option `-p` permet de le forcer.
En HA, chaque nœud ne sauvegarde que les bases qui tournent sur lui.

Autres outils de `up-tools/` :

| Script | Usage |
|---|---|
| `docker-volume-backup.sh -v VOLUME\|all -t DIR -d JOURS` | Sauvegarde d'un volume Docker (ex. `hotspotmanager_hm-data_vol01`). |
| `docker-hm-restore.sh -d DUMP.sql.gz -v VOLUME.tar.gz -t VOLUME -c CONTENEUR -p MOT_DE_PASSE` | Restauration Hotspot Manager (base + données). |
| `docker-host-infos.sh` | Inventaire de l'hôte (OS, Docker, services). |
| `up-setup.sh` (commande `up-setup`) | Assistant d'installation de la plateforme et des produits (voir plus haut). |
| `up-update.sh -s STACK -v VERSION` | Mise à jour d'un produit avec sauvegarde préalable (voir [Mettre à jour un produit](#mettre-à-jour-un-produit)). |
| `portainer-update.sh [-f] [-i IMAGE]` | Met à jour Portainer vers la dernière image (reprend les options du conteneur, garde les données, revient à l'ancien conteneur si le nouveau ne démarre pas). |
| `keepalived/keepalived.conf` | Exemple d'IP virtuelle partagée pour un cluster. |
| `stacks/` | Stacks utilitaires (filebrowser, agent Zabbix, Traefik docker-compose). |

## Migrer un serveur installé avec une ancienne ISO

Les anciens templates (`templates-swarm-*.json`) et leurs stacks (`*-compose/`) ont été supprimés.

1. Dans Portainer : *Settings → App Templates* → remplacer l'URL par celle de `templates.json` (voir plus haut).
2. Les stacks existantes continuent de fonctionner. Pour les mettre à jour, modifier `PRODUCT_VERSION` puis *Update the stack*.
   **Ne pas utiliser « Pull and redeploy »** sur une stack créée depuis un ancien template : son fichier YAML n'existe plus dans ce dépôt.
3. Pour passer sur les nouvelles stacks : sauvegarder, supprimer la stack **sans supprimer les volumes**, puis la recréer depuis le nouveau template
   **avec le même nom de stack** (les volumes portent le nom de la stack et sont repris). Opération à planifier.
