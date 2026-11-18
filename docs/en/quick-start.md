# Adipsys UP — Quick start

*[Version française](../demarrage-rapide.md)*

## Who is this for?

This guide installs an Adipsys UP server in about thirty minutes, in the most common case: **a single server**, installed **from the Adipsys ISO**, with **direct Internet access**.

For other cases (Debian already installed, corporate proxy), follow the [full installation guide](installation-guide.md).

## Before you start

- **A virtual machine**: 4 vCPU, 4 GB of RAM (8 GB for DNS Protect, 16 GB and 8 vCPU for several products on the same server), 100 GB SSD disk.
- **A fixed IP address** for the server, and Internet access over HTTPS (port 443).
- **The DNS names** of the products, for example `wifi.domain.com`, pointing to the server's public IP.
- **Your company's HTTPS certificate**, or nothing if you use Let's Encrypt (free, automatic certificate).
- **Provided by Adipsys**: the ISO download link and password, and your licence key.

## Step 1 — Install the server

1. Download `Adipsys_UP_trixie.iso` and boot the virtual machine from it.
2. Choose **Install** and answer the questions: language, keyboard, network (fixed IP), server name, root password. For partitioning, keep the proposed choice (entire disk).
3. Let the installation finish: the server reboots on its own. Allow 10 to 15 minutes.
4. On first boot, the server prepares Docker and Portainer in the background. Wait two or three minutes before the next step.

## Step 2 — Install the products

Log in as root (console or SSH) and start the wizard:

```bash
up-setup
```

The wizard's screens are in French. It checks the server, configures Portainer, then asks for:

- the **products** to install (Hotspot Manager, DNS Protect, Studio);
- their **DNS names**;
- the **certificate**: Let's Encrypt (automatic) or your company's.

It installs everything and ends with a summary: administration addresses and ports to open. This summary is kept in `/root/up-install-report.txt`, and the generated passwords in `/root/up-secrets.env`.

If it is interrupted, simply run `up-setup` again: completed steps are kept.

## Step 3 — Finish

1. **Firewall**: open the ports listed in the summary (at least 80 and 443 to the server; for Hotspot Manager, also 1812 and 1813 UDP from the Wi-Fi controller).
2. **Administration**: open the administration address given in the summary, log in with the account provided by Adipsys, enter your licence key and **change the password**.
3. **E-mail**: configure the SMTP server in the product's administration.

Your server is ready.

## Next

- **Update a product**: `up-update -l` lists the installed versions, then `up-update -s <product> -v <version>` installs the version given by Adipsys. Debian applies its security updates on its own.
- **Back up**: regularly copy `/root/up-secrets.env` and the product backups off the server.
- **Need help**: write to [support@adipsys.com](mailto:support@adipsys.com), attaching `/root/up-install-report.txt` and the log `/var/log/up-setup.log`. Never send `/root/up-secrets.env`.

For other cases (proxy, existing Debian, renewing a company certificate), see the [full installation guide](installation-guide.md).
