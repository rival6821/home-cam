#!/usr/bin/env bash
# 홈캠 릴레이 마스터플랜 §5.1(2단계) — Tailscale HTTPS 인증서 재발급.
#
# `tailscale cert`로 받은 인증서는 Let's Encrypt 표준 수명(90일)을 따르지만
# 이 방식으로 지정 경로에 내보낸 파일은 Tailscale이 스스로 갱신해주지 않는다.
# 이 스크립트를 cert-renew.timer(매월 1회)로 주기 실행해 만료를 막는다.
#
# 설치 위치: /usr/local/sbin/cert-renew.sh (setup.sh가 자동 배치)
# 수동 실행: sudo /usr/local/sbin/cert-renew.sh

set -euo pipefail

CERT_DIR="/etc/homecam/certs"
HOSTNAME_FILE="/etc/homecam/hostname"

if [ ! -f "$HOSTNAME_FILE" ]; then
  echo "오류: $HOSTNAME_FILE 이 없습니다. setup.sh를 먼저 실행하세요." >&2
  exit 1
fi
HOST="$(cat "$HOSTNAME_FILE")"

mkdir -p "$CERT_DIR"

echo "[cert-renew] $HOST 인증서 발급/갱신 중..."
tailscale cert \
  --cert-file="$CERT_DIR/$HOST.crt" \
  --key-file="$CERT_DIR/$HOST.key" \
  "$HOST"

# Caddy(caddy 계정으로 구동)가 읽을 수 있도록 소유권 조정.
# private key는 caddy 그룹만 읽도록 640으로 좁힌다.
chown root:caddy "$CERT_DIR/$HOST.crt" "$CERT_DIR/$HOST.key"
chmod 644 "$CERT_DIR/$HOST.crt"
chmod 640 "$CERT_DIR/$HOST.key"

echo "[cert-renew] Caddy에 갱신된 인증서 반영 중..."
systemctl reload caddy

echo "[cert-renew] 완료."
