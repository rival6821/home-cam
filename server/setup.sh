#!/usr/bin/env bash
###############################################################################
# 홈캠 릴레이 마스터플랜 §5.1 — VPS 배포 5단계를 순서대로 실행하는 부트스트랩.
#
# 대상: Ubuntu/Debian(apt) 기반 VPS. Oracle Cloud Free Tier의 Ubuntu 이미지
# 기준으로 작성했다. 다른 배포판이면 패키지 설치 부분만 손보면 된다.
#
# Caddy·MediaMTX는 Docker 컨테이너로 구동한다(docker-compose.yml). Tailscale은
# 인증서 발급이 호스트의 tailnet 신원에 묶여 있어 호스트에 네이티브로 남긴다
# — 자세한 이유는 docker-compose.yml 상단 주석 참고.
#
# 사용법:
#   sudo ./setup.sh <tailnet-호스트명> [포트]
#   예) sudo ./setup.sh cam-vps.tail1a2b3.ts.net
#   예) sudo ./setup.sh cam-vps.tail1a2b3.ts.net 8443   # 443이 이미 다른 용도로
#       점유된 VPS에서 — 접근이 Tailscale로 걸러지므로 443 고정일 필요가 없다.
#
# 선택: 미리 발급한 Tailscale Auth Key가 있으면 브라우저 인증 없이 자동 로그인.
#   sudo TS_AUTHKEY=tskey-auth-xxxx ./setup.sh cam-vps.tail1a2b3.ts.net
#
# 이 스크립트는 §5.1의 1→2→3→4→5 순서를 그대로 따르며, 되돌리기 어려운 단계
# (SSH 비밀번호 로그인 차단, 방화벽 잠금)는 안전 확인 후에만 진행한다.
###############################################################################
set -euo pipefail

HOST="${1:-}"
PORT="${2:-443}"
if [ -z "$HOST" ]; then
  echo "사용법: sudo $0 <tailnet-호스트명> [포트, 기본 443]" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "포트는 1~65535 사이 숫자여야 합니다: $PORT" >&2
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

apt-get update -y
apt-get install -y curl ufw ca-certificates

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

echo "  인증서를 먼저 발급합니다(Caddy는 4단계에서 컨테이너로 기동)."
install -m 0755 "$SCRIPT_DIR/cert-renew.sh" /usr/local/sbin/cert-renew.sh
/usr/local/sbin/cert-renew.sh || {
  echo "인증서 발급에 실패했습니다. 위 admin 콘솔 설정을 다시 확인하세요." >&2
  exit 1
}

###############################################################################
# 3단계 — Docker 설치 (§5.1-3, MediaMTX·Caddy의 실행 기반)
###############################################################################
echo "── 3/5 Docker 설치 ──"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# TAILSCALE_IP: docker-compose.yml이 Caddy를 이 IP에만 바인딩한다. "0.0.0.0"으로
# 게시하면 Docker가 ufw를 우회해 공인 인터넷에 노출될 수 있으므로(docker-compose.yml
# 상단 주석 참고) 반드시 구체적인 IP로 못박는다.
TAILSCALE_IP="$(tailscale ip -4)"
{
  echo "TAILSCALE_IP=$TAILSCALE_IP"
  echo "HOMECAM_PORT=$PORT"
} > "$SCRIPT_DIR/.env"
echo "  .env 생성: TAILSCALE_IP=$TAILSCALE_IP, HOMECAM_PORT=$PORT"

# 이 VPS를 다른 용도로도 쓰고 있으면 443(또는 지정한 포트)이 이미 nginx 등
# 다른 프로세스에 점유돼 있을 수 있다 — Docker가 뒤늦게 바인딩에 실패하며
# 애매한 오류를 내기 전에 여기서 미리 확인해 명확한 안내를 준다.
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"; then
  echo "  ⚠ 포트 $PORT 을(를) 이미 다른 프로세스가 쓰고 있습니다:" >&2
  ss -tlnp 2>/dev/null | grep ":$PORT " >&2 || true
  echo "    이 VPS를 다른 서비스와 같이 쓰고 있다면 다른 포트로 다시 실행하세요:" >&2
  echo "      sudo $0 $HOST <다른-포트>  (예: 8443)" >&2
  exit 1
fi

if [ ! -f "$STATE_DIR/mediamtx.yml" ]; then
  install -m 0600 "$SCRIPT_DIR/mediamtx.yml" "$STATE_DIR/mediamtx.yml"
  echo "  ⚠ $STATE_DIR/mediamtx.yml 의 CHANGE_ME_* PIN 값을 실제 PIN으로 바꾼 뒤"
  echo "    (server/ 디렉터리에서) 'docker compose restart mediamtx' 로 반영하세요."
else
  echo "  기존 $STATE_DIR/mediamtx.yml 을 덮어쓰지 않습니다(이미 설정됨)."
fi

###############################################################################
# 4단계 — Caddy 설정 및 컨테이너 스택 기동 (§5.1-4)
###############################################################################
echo "── 4/5 Caddy 설정 및 컨테이너 기동 ──"

if [ ! -f "$SCRIPT_DIR/../index.html" ] || [ ! -f "$SCRIPT_DIR/../camera.html" ]; then
  echo "  ⚠ camera.html / index.html을 찾지 못했습니다 — 저장소 루트에 두 파일이" >&2
  echo "    있어야 Caddy 컨테이너가 정적 파일을 서빙할 수 있습니다." >&2
  exit 1
fi

sed -e "s/YOUR-HOST.tailXXXXX.ts.net/$HOST/g" -e "s/HOMECAM_PORT_PLACEHOLDER/$PORT/g" \
  "$SCRIPT_DIR/Caddyfile" > "$STATE_DIR/Caddyfile"

(cd "$SCRIPT_DIR" && docker compose up -d)

###############################################################################
# 5단계 — 최종 방화벽 잠금 (§5.1-5)
###############################################################################
echo "── 5/5 방화벽 최종 잠금 ──"

ufw allow in on tailscale0
ufw allow 41641/udp comment 'Tailscale WireGuard'
ufw --force enable

PORT_SUFFIX=""
[ "$PORT" != "443" ] && PORT_SUFFIX=":$PORT"

echo
echo "════════════════════════════════════════════════════════════"
echo " 배포 완료 — 남은 수동 작업"
echo "════════════════════════════════════════════════════════════"
echo " 1) $STATE_DIR/mediamtx.yml 의 CHANGE_ME_* PIN을 실제 값으로 교체 후"
echo "    (server/ 디렉터리에서) docker compose restart mediamtx"
echo " 2) 카메라 폰: https://$HOST$PORT_SUFFIX/camera.html#cam=livingroom&pin=<발행PIN>"
echo " 3) 뷰어 기기: https://$HOST$PORT_SUFFIX/#cam=livingroom&pin=<시청PIN>"
echo " 4) 상태 확인: docker compose ps / docker compose logs -f (server/ 디렉터리에서)"
echo "════════════════════════════════════════════════════════════"
