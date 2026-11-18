# Adipsys – templates Portainer et outils UP

Ce dépôt contient tout ce que les serveurs **UP** (installés depuis l'ISO Adipsys) récupèrent depuis Internet :

- les **templates d'applications Portainer** des produits Adipsys ;
- les **stacks Docker Swarm** déployées par ces templates ;
- les **outils d'exploitation** (sauvegardes, restauration…) installés sur chaque serveur.

> ⚠️ Ce dépôt est **public** : n'y mettez jamais de mot de passe, de clé ou de donnée client.

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
| `up-tools/` | Scripts d'exploitation clonés sur chaque serveur dans `/usr/local/bin/public/up-tools/`. |

URL des templates à renseigner dans Portainer (*Settings → App Templates*) :

```
https://raw.githubusercontent.com/Adipsys/public/refs/heads/main/portainer-templates/templates.json
```

Les serveurs installés avec l'ISO actuelle sont déjà configurés avec cette URL.

## Installer un produit

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

Dans Portainer, ouvrir la stack → onglet *Editor* :

1. modifier la variable **`PRODUCT_VERSION`** ;
2. cliquer sur **Update the stack**.

Les images de l'application changent de version ; les volumes (données) sont conservés.
Il est conseillé de lancer une sauvegarde de la base juste avant (voir [Sauvegardes](#sauvegardes)).

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
