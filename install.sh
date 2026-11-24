#!/bin/sh
# Kälber-Management auf einem Hof-Rechner installieren: Raspberry Pi mit 64-Bit-System
# oder Linux-PC (Debian/Ubuntu). Holt das fertige Image – auf dem Hof liegt kein Quellcode.
#
#   curl -fsSL https://kalb-management.de/install.sh | sudo sh
#
# Nochmal starten = sofort auf den neuesten Stand bringen; die Daten in /opt/kaelber/data
# bleiben unangetastet. Ohne Rückfrage (Workflow, Fernwartung) über Umgebungsvariablen:
#   KAELBER_TOKEN  Zugangsschlüssel für das Image (leer = ohne Anmeldung)
#   KAELBER_IMAGE  anderes Image/Tag, z. B. …:develop
set -eu

IMAGE=${KAELBER_IMAGE:-ghcr.io/yannicknussbaum/kaelber-management:latest}
DIR=/opt/kaelber

fehler() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fehler "Dieses Skript ist für Raspberry Pi und Linux-PCs."
[ "$(id -u)" = 0 ] || fehler "Bitte mit sudo starten:  curl -fsSL https://kalb-management.de/install.sh | sudo sh"
case $(uname -m) in
  x86_64|aarch64|arm64) ;;
  armv7l|armv6l) fehler "Hier läuft ein 32-Bit-System. Bitte Raspberry Pi OS (64-bit) aufspielen – geht ab Raspberry Pi 3." ;;
  *) fehler "Prozessor $(uname -m) wird nicht unterstützt." ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "→ Docker installieren (dauert ein paar Minuten) …"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || fehler "Docker Compose fehlt:  apt install docker-compose-plugin"

# Zugangsschlüssel nur beim ersten Mal; bei einem Update ist Docker schon angemeldet.
# Gelesen von /dev/tty, weil die Standardeingabe bei „curl | sh“ das Skript selbst ist.
if [ -z "${KAELBER_TOKEN+x}" ] && ! grep -qs '"ghcr.io"' "$HOME/.docker/config.json"; then
  printf 'Zugangsschlüssel eingeben (leer lassen, falls keiner nötig): '
  read -r KAELBER_TOKEN < /dev/tty || KAELBER_TOKEN=
fi
if [ -n "${KAELBER_TOKEN:-}" ]; then
  printf '%s' "$KAELBER_TOKEN" | docker login ghcr.io -u yannicknussbaum --password-stdin >/dev/null \
    || fehler "Zugangsschlüssel wurde nicht angenommen."
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}') || IP=
ZEITZONE=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null) || ZEITZONE=

mkdir -p "$DIR/data"
cat > "$DIR/docker-compose.yml" <<EOF
# Angelegt von install.sh – wird bei jedem Lauf neu geschrieben, die Daten in ./data bleiben.
services:
  kaelber:
    image: $IMAGE
    ports:
      - "3000:3000"   # HTTP, leitet auf HTTPS um
      - "3443:3443"   # HTTPS – die App
    volumes:
      - ./data:/app/data
    environment:
      - DB_DIR=/app/data
      - CERT_DIR=/app/data/certs
      - TZ=${ZEITZONE:-Europe/Brussels}
      - EXTRA_SAN_IPS=$IP
    restart: unless-stopped
EOF

cd "$DIR"
echo "→ App laden …"
docker compose pull -q || fehler "Die App konnte nicht geladen werden. Zugangsschlüssel richtig? Nochmal starten fragt erneut, vorher:  sudo docker logout ghcr.io"
docker compose up -d

# Nachts um 3 Uhr die neueste Version holen; alte Images löschen, sonst läuft die SD-Karte voll.
if [ -d /etc/cron.d ]; then
  cat > /etc/cron.d/kaelber-update <<EOF
# Kälber-Management: jede Nacht neueste Version holen (angelegt von install.sh)
0 3 * * * root cd $DIR && (docker compose pull -q && docker compose up -d && docker image prune -f) >/dev/null 2>&1
EOF
  UPDATES="automatisch jede Nacht um 3 Uhr"
else
  UPDATES="dieses Skript erneut starten (cron fehlt, daher kein automatisches Update)"
fi

printf '→ Warten, bis die App läuft '
i=0
until VERSION=$(curl -fsk https://localhost:3443/api/version 2>/dev/null); do
  i=$((i + 1))
  [ "$i" -le 60 ] || fehler "Die App startet nicht. Protokoll ansehen:  cd $DIR && sudo docker compose logs"
  printf .
  sleep 2
done
VERSION=$(printf '%s' "$VERSION" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')

cat <<EOF


✅ Kälber-Management $VERSION läuft.

   Im Browser öffnen:  https://${IP:-<IP-dieses-Geräts>}:3443
   Die Warnung zum Zertifikat einmal bestätigen, dann führt die Ersteinrichtung weiter.

   Daten:    $DIR/data  (Sicherung = kaelber.db kopieren)
   Updates:  $UPDATES
EOF
