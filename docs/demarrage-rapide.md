# Adipsys UP — Démarrage rapide

*[English version](en/quick-start.md)*

## Pour qui ?

Ce guide installe un serveur Adipsys UP en une trentaine de minutes, dans le cas le plus courant : **un seul serveur**, installé **avec l'ISO Adipsys**, avec un **accès direct à Internet**.

Le lien de téléchargement de l'ISO vous sera fourni par email, si vous n'en disposez pas, merci de contacter le support.

Dans les autres cas (Debian déjà installée, proxy d'entreprise), suivez le [guide d'installation complet](guide-installation.md).

## Avant de commencer

- **Une machine virtuelle** : 4 vCPU, 4 Go de RAM (8 Go pour DNS Protect, 16 Go et 8 vCPU pour plusieurs produits sur le même serveur), 100 Go de disque SSD.
- **Une adresse IP fixe** pour le serveur, et un accès à Internet en HTTPS (port 443).
- **Les noms DNS** des produits, par exemple `wifi.domaine.fr`, qui pointent vers l'IP publique du serveur.
- **Le certificat HTTPS** de votre entreprise, ou rien si vous utilisez Let's Encrypt (certificat gratuit et automatique).
- **Fourni par Adipsys** : le lien et le mot de passe de téléchargement de l'ISO, et votre clé de licence.

## Étape 1 — Installer le serveur

1. Téléchargez `Adipsys_UP_trixie.iso` et démarrez la machine virtuelle dessus.
2. Choisissez **Install** et répondez aux questions : langue, clavier, réseau (IP fixe), nom du serveur, mot de passe root. Pour le partitionnement, gardez le choix proposé (disque entier).
3. Laissez l'installation se terminer : le serveur redémarre seul. Comptez 10 à 15 minutes.
4. Au premier démarrage, le serveur prépare Docker et Portainer en tâche de fond. Attendez deux ou trois minutes avant l'étape suivante.

## Étape 2 — Installer les produits

Connectez-vous en root (console ou SSH) et lancez l'assistant :

```bash
up-setup
```

L'assistant vérifie le serveur, configure Portainer, puis vous demande :

- les **produits** à installer (Hotspot Manager, DNS Protect, Studio) ;
- leurs **noms DNS** ;
- le **certificat** : Let's Encrypt (automatique) ou celui de votre entreprise.

Il installe tout et termine par un récapitulatif : adresses d'administration et ports à ouvrir. Ce récapitulatif est conservé dans `/root/up-install-report.txt`, et les mots de passe générés dans `/root/up-secrets.env`.

En cas d'interruption, relancez simplement `up-setup` : les étapes déjà faites sont conservées.

## Étape 3 — Finaliser

1. **Pare-feu** : ouvrez les ports indiqués dans le récapitulatif (au minimum 80 et 443 vers le serveur ; pour Hotspot Manager, aussi 1812 et 1813 en UDP depuis le contrôleur Wi-Fi).
2. **Administration** : ouvrez l'adresse d'administration donnée par le récapitulatif, connectez-vous avec le compte fourni par Adipsys, saisissez votre clé de licence et **changez le mot de passe**.
3. **E-mails** : configurez le serveur SMTP dans l'administration du produit.

Votre serveur est prêt.

## Ensuite

- **Mettre à jour un produit** : `up-update -l` affiche les versions installées, puis `up-update -s <produit> -v <version>` installe celle indiquée par Adipsys. Le système Debian applique seul ses mises à jour de sécurité.
- **Sauvegarder** : copiez régulièrement `/root/up-secrets.env` et les sauvegardes des produits hors du serveur.
- **Besoin d'aide** : écrivez à [support@adipsys.com](mailto:support@adipsys.com) en joignant le fichier `/root/up-install-report.txt` et le journal `/var/log/up-setup.log`. N'envoyez jamais `/root/up-secrets.env`.

Pour les autres cas (proxy, Debian existante, certificat d'entreprise à renouveler), reportez-vous au [guide d'installation complet](guide-installation.md).
