#!/usr/bin/env bash
###############################################################################
# 홈캠 릴레이 마스터플랜 §5.1 — VPS 배포 5단계를 순서대로 실행하는 부트스트랩.
#
# 대상: Ubuntu/Debian(apt) 기반 VPS. Oracle Cloud Free Tier의 Ubuntu 이미지
# 기준으로 작성했다. 다른 배포판이면 패키지 설치 부분만 손보면 된다.
#
# 사용법:
#   sudo ./setup.sh <tailnet-호스트명>
#   예) sudo ./setup.sh cam-vps.tail1a2b3.ts.net
#
# 선택: 미리 발급한 Tailscale Auth Key가 있으면 브라우저 인증 없이 자동 로그인.
#   sudo TS_AUTHKEY=tskey-auth-xxxx ./setup.sh cam-vps.tail1a2b3.ts.net
#
# 이 스크립트는 §5.1의 1→2→3→4→5 순서를 그대로 따르며, 되돌리기 어려운 단계
# (SSH 비밀번호 로그인 차단, 방화벽 잠금)는 안전 확인 후에만 진행한다.
###############################################################################
set -euo pipefail

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "사용법: sudo $0 <tailnet-호스트명>  (예: cam-vps.tail1a2b3.ts.net)" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한으로 실행하세요 (sudo $0 $HOST)" >&2
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "이 스크립트는 apt 기반 배포판(Ubuntu/Debian)을 가정합니다." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/etc/homecam"

echo "════════════════════════════════════════════════════════════"
echo " 홈캠 릴레이 배포 시작 — 대상 호스트: $HOST"
echo "════════════════════════════════════════════════════════════"

###############################################################################
# 1단계 — VPS 초기 하드닝 (§5.1-1)
###############################################################################
echo "── 1/5 초기 하드닝 ──"

mkdir -p "$STATE_DIR" "$STATE_DIR/certs"
echo "$HOST" > "$STATE_DIR/hostname"

id -u homecam >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin homecam
chown -R homecam:homecam "$STATE_DIR"

apt-get update -y
apt-get install -y curl ufw

# SSH 비밀번호 로그인 차단은 "되돌리기 어려운" 조치이므로, 키 기반 접속이
# 이미 확보된 경우에만 진행한다 — 확인 없이 껐다가는 원격 접속 자체가
# 막힐 수 있다.
AUTH_KEYS_FOUND=0
for f in /root/.ssh/authorized_keys "${SUDO_USER:+/home/$SUDO_USER/.ssh/authorized_keys}"; do
  if [ -n "${f:-}" ] && [ -s "$f" ]; then AUTH_KEYS_FOUND=1; fi
done
if [ "$AUTH_KEYS_FOUND" -eq 1 ]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl reload sshd || systemctl reload ssh || true
  echo "  SSH 키 접속 확인됨 — 비밀번호 로그인을 비활성화했습니다."
else
  echo "  ⚠ authorized_keys를 찾지 못해 SSH 비밀번호 로그인은 그대로 둡니다."
  echo "    키 등록 후 /etc/ssh/sshd_config에서 PasswordAuthentication no로 직접 바꾸세요."
fi

# 방화벽은 5단계에서 최종 잠금 — 지금은 기본 정책만 세팅(아직 enable 안 함).
ufw default deny incoming
ufw default allow outgoing

###############################################################################
# 2단계 — Tailscale 설치 및 HTTPS 인증서 발급 (§5.1-2)
###############################################################################
echo "── 2/5 Tailscale 설치 및 인증서 발급 ──"

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! tailscale status >/dev/null 2>&1; then
  if [ -n "${TS_AUTHKEY:-}" ]; then
    tailscale up --authkey="$TS_AUTHKEY"
  else
    echo "  브라우저에서 로그인 링크를 열어 이 기기를 tailnet에 등록하세요."
    tailscale up
  fi
fi

cat <<'EOF'

  ⚠ 수동 확인 필요 (Tailscale 관리 콘솔, 최초 1회만):
    1) https://login.tailscale.com/admin/dns 접속
    2) "Enable MagicDNS" 활성화
    3) "HTTPS Certificates" 활성화 (머신명·tailnet 이름이 공개 인증서
       투명성 로그에 게시된다는 안내에 동의 — §1.5에 이미 기술된 내용)

EOF
read -r -p "  위 설정을 마쳤으면 Enter를 눌러 계속하세요..." _

echo "  Caddy 설치 전, 인증서를 먼저 발급합니다."
install -m 0755 "$SCRIPT_DIR/cert-renew.sh" /usr/local/sbin/cert-renew.sh

###############################################################################
# 3단계 — MediaMTX 설치 (§5.1-3)
###############################################################################
echo "── 3/5 MediaMTX 설치 ──"

case "$(uname -m)" in
  x86_64)  MTX_ARCH=amd64 ;;
  aarch64) MTX_ARCH=arm64 ;;
  *) echo "지원하지 않는 아키텍처입니다: $(uname -m)" >&2; exit 1 ;;
esac

if ! command -v mediamtx >/dev/null 2>&1; then
  DL_URL="$(curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
    | grep -o "\"browser_download_url\": *\"[^\"]*linux_${MTX_ARCH}\.tar\.gz\"" \
    | head -n1 | sed -E 's/.*"(https[^"]+)"/\1/')"
  if [ -z "$DL_URL" ]; then
    echo "MediaMTX 다운로드 URL을 자동으로 찾지 못했습니다." >&2
    echo "https://github.com/bluenviron/mediamtx/releases 에서 linux_${MTX_ARCH}.tar.gz를 받아" >&2
    echo "mediamtx 바이너리를 /usr/local/bin/mediamtx 에 직접 설치한 뒤 다시 실행하세요." >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  curl -fsSL "$DL_URL" -o "$TMP/mediamtx.tar.gz"
  tar -xzf "$TMP/mediamtx.tar.gz" -C "$TMP"
  install -m 0755 "$TMP/mediamtx" /usr/local/bin/mediamtx
  rm -rf "$TMP"
fi

if [ ! -f "$STATE_DIR/mediamtx.yml" ]; then
  install -m 0640 -o homecam -g homecam "$SCRIPT_DIR/mediamtx.yml" "$STATE_DIR/mediamtx.yml"
  echo "  ⚠ $STATE_DIR/mediamtx.yml 의 CHANGE_ME_* PIN 값을 실제 PIN으로 바꾼 뒤"
  echo "    'sudo systemctl restart mediamtx' 로 반영하세요."
else
  echo "  기존 $STATE_DIR/mediamtx.yml 을 덮어쓰지 않습니다(이미 설정됨)."
fi

install -m 0644 "$SCRIPT_DIR/mediamtx.service" /etc/systemd/system/mediamtx.service

###############################################################################
# 4단계 — Caddy 설치 및 동일 출처 통합 (§5.1-4)
###############################################################################
echo "── 4/5 Caddy 설치 ──"

if ! command -v caddy >/dev/null 2>&1; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

mkdir -p /var/www/homecam
if [ -f "$SCRIPT_DIR/../index.html" ] && [ -f "$SCRIPT_DIR/../camera.html" ]; then
  cp "$SCRIPT_DIR/../index.html" "$SCRIPT_DIR/../camera.html" /var/www/homecam/
  echo "  camera.html / index.html 을 /var/www/homecam/ 에 배치했습니다."
else
  echo "  ⚠ camera.html / index.html을 찾지 못했습니다 — /var/www/homecam/ 에 직접 업로드하세요."
fi
chown -R caddy:caddy /var/www/homecam

sed "s/YOUR-HOST.tailXXXXX.ts.net/$HOST/g" "$SCRIPT_DIR/Caddyfile" > /etc/caddy/Caddyfile

# 이제 인증서를 발급(§5.1-2에서 준비만 해둔 것을 여기서 실행) — Caddy가
# 시작 시점부터 유효한 cert/key를 찾을 수 있도록 Caddy 설치 직후, 첫 시작 전에 실행.
/usr/local/sbin/cert-renew.sh || {
  echo "인증서 발급에 실패했습니다. 2단계의 admin 콘솔 설정을 다시 확인하세요." >&2
  exit 1
}

install -m 0644 "$SCRIPT_DIR/cert-renew.service" /etc/systemd/system/cert-renew.service
install -m 0644 "$SCRIPT_DIR/cert-renew.timer" /etc/systemd/system/cert-renew.timer

systemctl daemon-reload
systemctl enable --now mediamtx
systemctl enable --now cert-renew.timer
systemctl restart caddy
systemctl enable caddy

###############################################################################
# 5단계 — 최종 방화벽 잠금 (§5.1-5)
###############################################################################
echo "── 5/5 방화벽 최종 잠금 ──"

ufw allow in on tailscale0
ufw allow 41641/udp comment 'Tailscale WireGuard'
ufw --force enable

echo
echo "════════════════════════════════════════════════════════════"
echo " 배포 완료 — 남은 수동 작업"
echo "════════════════════════════════════════════════════════════"
echo " 1) $STATE_DIR/mediamtx.yml 의 CHANGE_ME_* PIN을 실제 값으로 교체 후"
echo "    sudo systemctl restart mediamtx"
echo " 2) 카메라 폰: https://$HOST/camera.html#cam=livingroom&pin=<발행PIN>"
echo " 3) 뷰어 기기: https://$HOST/#cam=livingroom&pin=<시청PIN>"
echo " 4) 상태 확인: systemctl status mediamtx caddy"
echo "════════════════════════════════════════════════════════════"
