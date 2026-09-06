# 배포 실행 가이드

`master-plan.html`(설계 근거)과 `camera.html`/`index.html`(프런트엔드)에 대응하는
실제 배포 절차. 전체 배경·수치 근거는 마스터플랜 문서를 참조하고, 이 문서는
터미널에서 그대로 따라 칠 수 있는 실행 순서만 담는다.

## 준비물

- Ubuntu/Debian 기반 VPS 1대 (권장: Oracle Cloud Free Tier — §0 참조), SSH 접속 가능
- 이 저장소 전체를 VPS에 업로드 (`scp -r . user@vps:~/home-cam`)
- Tailscale 계정

## 1. 최초 배포 (한 번만)

```bash
ssh user@vps
cd ~/home-cam/server
sudo ./setup.sh <실제-tailnet-호스트명>
```

호스트명은 아직 모른다면 `tailscale up`을 먼저 대화형으로 한 번 실행해
Tailscale 관리 콘솔(https://login.tailscale.com/admin/machines)에서 이 머신에
할당된 `*.ts.net` 이름을 확인한 뒤 그 값으로 실행한다.

스크립트가 중간에 한 번 멈추고 Tailscale 관리 콘솔에서 **MagicDNS**와
**HTTPS Certificates**를 켜 달라고 안내한다 — 이건 웹 UI에서만 되는 설정이라
자동화할 수 없다. 켠 뒤 Enter를 누르면 나머지가 이어서 진행된다.

## 2. PIN 설정 (필수 — 기본값은 자리 표시자다)

```bash
sudo nano /etc/homecam/mediamtx.yml
# CHANGE_ME_10CHAR_PUBLISH_PIN, CHANGE_ME_FAMILY_VIEWER_PIN 을
# 각각 §4.1 기준 10자리 영문/숫자 PIN으로 교체

sudo systemctl restart mediamtx
```

카메라를 추가할 때(예: 안방)도 같은 파일에 `cam-bedroom` 계정 블록을 하나 더
추가하고 재시작하면 된다(파일 안 주석에 예시 있음).

## 3. 접속 확인

| 기기 | URL |
|---|---|
| 카메라(구형 안드로이드, Chrome) | `https://<호스트>/camera.html#cam=livingroom&pin=<게시PIN>` |
| 뷰어(아이폰·가족 기기) | `https://<호스트>/#cam=livingroom&pin=<시청PIN>` |

마스터플랜 §6 Phase 1~2 순서대로: 먼저 PC 브라우저 두 탭으로 왕복 확인 →
실제 구형 폰으로 송출 → LTE 아이폰으로 시청.

**연결되는데 화면이 검게만 나오면** 거의 항상 코덱 불일치다(§2.1, §7 최빈 원인) —
서버 설정이 아니라 두 프런트엔드 파일이 최신 버전인지부터 확인한다.

## 4. 운영 중 점검 명령

```bash
# 서비스 상태
sudo systemctl status mediamtx caddy cert-renew.timer

# 로그
sudo journalctl -u mediamtx -f
sudo journalctl -u caddy -f

# 현재 접속 세션 확인(§4.3) — 로컬에서만 접근 가능하므로 SSH 터널 필요
ssh -L 9997:127.0.0.1:9997 user@vps
# 이후 로컬 브라우저에서 http://127.0.0.1:9997/v3/paths/list

# 인증서 수동 갱신(평소엔 cert-renew.timer가 매월 자동 실행)
sudo /usr/local/sbin/cert-renew.sh
```

## 5. 방화벽 확인

`setup.sh`가 마지막 단계에서 UFW를 잠근다. 배포 후 반드시 확인:

```bash
sudo ufw status verbose
# 기대 결과: 41641/udp(Tailscale)만 허용, 그 외 incoming 전체 거부.
# 443/80이 이 목록에 없어야 정상이다 — Caddy는 Tailscale 인터페이스로만
# 도달 가능해야 한다("ufw allow in on tailscale0"가 이를 담당).
```

## 파일 지도

| 경로 | 배포 위치 | 용도 |
|---|---|---|
| `index.html` | `/var/www/homecam/index.html` | 뷰어(가족 시청) |
| `camera.html` | `/var/www/homecam/camera.html` | 카메라 송출 |
| `server/mediamtx.yml` | `/etc/homecam/mediamtx.yml` | WHIP/WHEP·인증·저장 정책 |
| `server/Caddyfile` | `/etc/caddy/Caddyfile` | TLS 종단·리버스 프록시·보안 헤더 |
| `server/mediamtx.service` | `/etc/systemd/system/` | MediaMTX 상시 구동 |
| `server/cert-renew.{sh,service,timer}` | `/usr/local/sbin/`, `/etc/systemd/system/` | 인증서 매월 자동 갱신 |

`setup.sh`가 위 배치를 전부 자동으로 수행한다 — 표는 "무엇이 왜 거기 있는지"
나중에 찾아볼 때를 위한 참조용이다.
