# 배포 실행 가이드

`master-plan.html`(설계 근거)과 `camera.html`/`index.html`(프런트엔드)에 대응하는
실제 배포 절차. 전체 배경·수치 근거는 마스터플랜 문서를 참조하고, 이 문서는
터미널에서 그대로 따라 칠 수 있는 실행 순서만 담는다.

## 준비물

- Ubuntu/Debian 기반 VPS 1대 (권장: Oracle Cloud Free Tier — §0 참조), SSH 접속 가능
- 이 저장소를 VPS에 클론 (`git clone https://github.com/rival6821/home-cam.git ~/home-cam`) —
  이후 프런트엔드 수정분은 `git pull` 한 번으로 반영되므로(§2-1), `scp`로 매번
  업로드하는 것보다 이 방식을 권장한다
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

cd ~/home-cam/server
docker compose restart mediamtx
```

카메라를 추가할 때(예: 안방)도 같은 파일에 `cam-bedroom` 계정 블록을 하나 더
추가하고 재시작하면 된다(파일 안 주석에 예시 있음).

## 2-1. 프런트엔드(index.html/camera.html) 수정분 반영

Caddy 컨테이너가 이 두 파일을 저장소 경로에서 직접 바인드 마운트하므로,
로컬에서 코드를 고친 뒤 VPS에서 `git pull`만 하면 그대로 반영된다 — 컨테이너
재시작도 필요 없다(정적 파일이라 Caddy가 요청마다 디스크에서 새로 읽는다).

```bash
ssh user@vps
cd ~/home-cam && git pull
```

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
cd ~/home-cam/server

# 컨테이너 상태
docker compose ps

# 로그
docker compose logs -f mediamtx
docker compose logs -f caddy

# Tailscale·인증서 타이머 상태(이 둘은 호스트 네이티브라 systemd 그대로)
sudo systemctl status tailscaled cert-renew.timer

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
# 443/80이 이 목록에 없어야 정상이다 — Caddy 컨테이너는 Tailscale IP에만
# 바인딩되어 있어야 한다(docker-compose.yml의 "${TAILSCALE_IP}:443:443").

# Docker가 ufw를 우회해 443을 공인 인터넷에 열어버리지 않았는지 직접 확인:
sudo ss -tlnp | grep :443
# 기대 결과: "100.x.x.x:443"처럼 Tailscale IP 하나만 보여야 한다.
# "0.0.0.0:443"이 보이면 docker-compose.yml의 ports 바인딩이 잘못된 것이다.
```

## 파일 지도

| 경로 | 배포 위치 | 용도 |
|---|---|---|
| `index.html` | Caddy 컨테이너에 바인드 마운트(저장소 경로 그대로) | 뷰어(가족 시청) |
| `camera.html` | Caddy 컨테이너에 바인드 마운트(저장소 경로 그대로) | 카메라 송출 |
| `server/mediamtx.yml` | `/etc/homecam/mediamtx.yml` → mediamtx 컨테이너에 마운트 | WHIP/WHEP·인증·저장 정책 |
| `server/Caddyfile` | `/etc/homecam/Caddyfile` → caddy 컨테이너에 마운트 | TLS 종단·리버스 프록시·보안 헤더 |
| `server/docker-compose.yml` | `~/home-cam/server/`에서 그대로 실행 | Caddy·MediaMTX 컨테이너 오케스트레이션 |
| `server/cert-renew.{sh,service,timer}` | `/usr/local/sbin/`, `/etc/systemd/system/` | 인증서 매월 자동 갱신(호스트 네이티브) |

`setup.sh`가 위 배치를 전부 자동으로 수행한다 — 표는 "무엇이 왜 거기 있는지"
나중에 찾아볼 때를 위한 참조용이다. Tailscale·SSH·ufw만 호스트에 직접 설치되고,
Caddy·MediaMTX는 컨테이너다(이유는 `server/docker-compose.yml` 상단 주석 참고).
