#!/usr/bin/env bash
#
# install-docker-engine.sh — Installation de Docker Engine + Compose plugin
# via le dépôt APT officiel Docker, clé GPG vérifiée contre l'empreinte
# publiée sur docs.docker.com.
#
# Prérequis pour install-immich.sh et install-vaultwarden.sh.
#
# Usage :
#   sudo ./install-docker-engine.sh
#   sudo ./install-docker-engine.sh --dry-run
#
# Idempotent : si Docker Engine (le vrai, pas le paquet docker.io d'Ubuntu)
# est déjà installé, le script s'arrête sans rien casser.

set -Eeuo pipefail

DRY_RUN=0
DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
KEYRING="/etc/apt/keyrings/docker.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"
TMPDIR_KEY=""

if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[0;33m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()    { printf '%s [OK]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()   { trap - ERR; printf '%s[ERREUR]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
dry()   { printf '%s[dry-run]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }

run() { if [[ "$DRY_RUN" -eq 1 ]]; then dry "$*"; else "$@"; fi; }

write_file() {
  local path="$1" content
  content="$(cat)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "écriture de $path :"
    printf '%s\n' "$content" | sed 's/^/           | /'
  else
    printf '%s\n' "$content" > "$path"
  fi
}

cleanup() { [[ -n "$TMPDIR_KEY" && -d "$TMPDIR_KEY" ]] && rm -rf -- "$TMPDIR_KEY"; }
trap cleanup EXIT
trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s[MODE SIMULATION]%s\n' "$C_WARN" "$C_OFF"
fi

info "Vérifications préalables"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  [[ "$DRY_RUN" -eq 1 ]] && warn "Pas root : vérifications limitées." || die "Lancez avec sudo."
fi

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ce script vise spécifiquement Ubuntu (dépôt Docker dédié)."
ok "Système : ${PRETTY_NAME:-$ID $VERSION_ID}"

ARCH="$(dpkg --print-architecture)"
ok "Architecture : $ARCH"

# Docker Engine déjà installé (le vrai, pas docker.io) ?
if command -v docker >/dev/null 2>&1 && dpkg -l docker-ce >/dev/null 2>&1; then
  ok "Docker Engine déjà installé ($(docker --version 2>/dev/null)). Rien à faire."
  exit 0
fi

if dpkg -l docker.io >/dev/null 2>&1; then
  die "Le paquet 'docker.io' (version Ubuntu, souvent obsolète) est installé.
      Retirez-le avant de continuer :
      sudo apt remove -y docker.io
      Vos volumes dans /var/lib/docker sont conservés."
fi

if ! curl -fsSI --max-time 15 "$DOCKER_KEY_URL" >/dev/null; then
  die "Impossible de joindre $DOCKER_KEY_URL — vérifiez DNS / réseau / proxy."
fi
ok "Accès réseau au dépôt Docker confirmé"

info "Installation des dépendances"
export DEBIAN_FRONTEND=noninteractive
run apt-get update -qq
run apt-get install -y -qq ca-certificates curl gnupg
[[ "$DRY_RUN" -eq 1 ]] || ok "Dépendances en place"

info "Récupération et vérification de la clé de signature Docker"
TMPDIR_KEY="$(mktemp -d)"
chmod 700 "$TMPDIR_KEY"
curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "$TMPDIR_KEY/docker.key" "$DOCKER_KEY_URL"

FOUND_FPR="$(gpg --homedir "$TMPDIR_KEY" --batch --with-colons \
                 --show-keys --fingerprint "$TMPDIR_KEY/docker.key" 2>/dev/null \
             | awk -F: '/^fpr:/ {print $10; exit}' || true)"

if [[ "$FOUND_FPR" != "$DOCKER_KEY_FPR" ]]; then
  die "Empreinte de clé Docker inattendue !
      attendue : $DOCKER_KEY_FPR
      obtenue  : ${FOUND_FPR:-<vide>}
   Installation interrompue par sécurité."
fi
ok "Empreinte vérifiée : $FOUND_FPR"

install -d -m 0755 /etc/apt/keyrings
gpg --batch --yes --dearmor -o "$TMPDIR_KEY/docker.gpg" "$TMPDIR_KEY/docker.key"
run install -m 0644 -o root -g root "$TMPDIR_KEY/docker.gpg" "$KEYRING"
[[ "$DRY_RUN" -eq 1 ]] || ok "Trousseau installé : $KEYRING"

info "Configuration du dépôt APT Docker"
write_file "$SOURCES_FILE" <<EOF
Types: deb
URIs: $DOCKER_REPO_URL
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $ARCH
Signed-By: $KEYRING
EOF
run chmod 0644 "$SOURCES_FILE"
ok "Dépôt déclaré : $SOURCES_FILE"

info "Installation de Docker Engine, CLI, containerd et le plugin Compose"
run apt-get update -qq
run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

run systemctl daemon-reload
run systemctl enable --now docker

if [[ "$DRY_RUN" -eq 0 ]]; then
  info "Vérification du fonctionnement (hello-world)"
  if docker run --rm hello-world >/dev/null 2>&1; then
    ok "Docker fonctionne correctement"
  else
    warn "Le test hello-world a échoué. Diagnostic : systemctl status docker"
  fi
fi

CALLER_USER="${SUDO_USER:-}"
if [[ -n "$CALLER_USER" && "$DRY_RUN" -eq 0 ]]; then
  run usermod -aG docker "$CALLER_USER"
  ok "Utilisateur '$CALLER_USER' ajouté au groupe docker (déconnexion/reconnexion nécessaire pour éviter 'sudo docker')"
fi

DOCKER_VERSION="$(docker --version 2>/dev/null || echo "non installé")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────
 Simulation terminée — rien n'a été modifié
────────────────────────────────────────────────────────────────
EOF
  exit 0
fi

cat <<EOF

────────────────────────────────────────────────────────────────
 ${C_OK}Docker Engine installé${C_OFF}
────────────────────────────────────────────────────────────────
 $DOCKER_VERSION
 Compose : $(docker compose version 2>/dev/null || echo "non détecté")
────────────────────────────────────────────────────────────────
EOF
