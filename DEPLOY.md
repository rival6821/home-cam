# 배포 지침서 — 프런트엔드·백엔드를 VPS에 올리기

`master-plan.html`(설계 근거)과 `camera.html`/`index.html`(프런트엔드),
`server/`(백엔드: Caddy·MediaMTX 컨테이너 + 호스트 Tailscale)에 대응하는 실제
배포 절차. 전체 배경·수치 근거는 마스터플랜 문서를 참조하고, 이 문서는
터미널에서 그대로 따라 칠 수 있는 실행 순서만 담는다.

**한 줄 요약**: VPS 하나에 백엔드(Caddy+MediaMTX 컨테이너, Tailscale 호스트
네이티브)를 최초 1회 `setup.sh`로 배포하고, 프런트엔드(정적 HTML 2개)는 그
VPS의 저장소 클론을 Caddy가 직접 바인드 마운트하므로 이후 수정은 `git pull`
한 번으로 끝난다. 두 배포 대상이 같은 저장소·같은 서버에 함께 있다.

## 목차

0. [사전 준비](#0-사전-준비)
1. [백엔드 최초 배포](#1-백엔드-최초-배포-한-번만)
2. [PIN 설정](#2-pin-설정-필수--기본값은-자리-표시자다)
3. [프런트엔드 배포·갱신](#3-프런트엔드-배포갱신)
4. [접속 확인](#4-접속-확인)
5. [운영 중 점검 명령](#5-운영-중-점검-명령)
6. [방화벽 확인](#6-방화벽-확인)
7. [파일 지도](#파일-지도)

## 0. 사전 준비

- **VPS 1대**: Ubuntu/Debian 기반, SSH 접속 가능 (권장: Oracle Cloud Free Tier
  — 사양 근거는 마스터플랜 §0 참조)
- **Oracle Cloud를 쓴다면, VCN Security List에 UDP 41641 인바운드 규칙을 하나
  추가한다** — `ufw`는 VM 안의 방화벽이고, Oracle VCN Security List는 그보다
  바깥, 클라우드 네트워크 레벨의 별도 방화벽이다. 이 규칙이 없어도 Tailscale
  자체는 동작하지만(양쪽 다 아웃바운드로 시도하다 안 되면 DERP 릴레이로
  폴백), 마스터플랜 §1.3이 전제하는 "DERP 없는 직결(대역폭·지연 손실 없음)"이
  깨진다. VCN → Security Lists → Add Ingress Rule: Source `0.0.0.0/0`,
  IP Protocol `UDP`, Destination Port `41641`. 그 외 인바운드 규칙(기본으로
  열려 있는 것 포함)은 최소화하고, 최종 관문은 어차피 `ufw`(§6)가 담당한다.
- **저장소 클론**:
  ```bash
  ssh user@vps
  git clone https://github.com/rival6821/home-cam.git ~/home-cam
  ```
  `scp`로 매번 파일을 올리지 않는 이유: 백엔드 설정(`server/`)과 프런트엔드
  파일이 이미 이 클론 안에 함께 있고, 이후 프런트엔드 수정분은 여기서
  `git pull` 한 번으로 반영되기 때문이다(§3).
- **Tailscale 계정** (무료 Personal 플랜으로 충분 — 마스터플랜 §1.3)
- **이 VPS를 다른 용도로 이미 쓰고 있다면, 443이 비어있는지 먼저 확인한다**:
  ```bash
  sudo ss -tlnp | grep :443
  ```
  뭔가(대개 nginx) 이미 443을 쓰고 있으면 `setup.sh` 실행 시 다른 포트를
  지정하면 된다(§1) — 어차피 접근은 Tailscale로만 걸러지므로 443 고정일
  필요가 없다. `setup.sh`도 이 상태를 자체적으로 감지해 명확한 오류를 낸다.

## 1. 백엔드 최초 배포 (한 번만)

```bash
cd ~/home-cam/server
sudo ./setup.sh <실제-tailnet-호스트명>
# 443이 이미 다른 서비스(예: nginx)에 점유돼 있다면 두 번째 인자로 다른 포트를:
sudo ./setup.sh <실제-tailnet-호스트명> 8443
```

호스트명은 아직 모른다면 `tailscale up`을 먼저 대화형으로 한 번 실행해
Tailscale 관리 콘솔(https://login.tailscale.com/admin/machines)에서 이 머신에
할당된 `*.ts.net` 이름을 확인한 뒤 그 값으로 실행한다.

스크립트가 중간에 한 번 멈추고 Tailscale 관리 콘솔에서 **MagicDNS**와
**HTTPS Certificates**를 켜 달라고 안내한다 — 이건 웹 UI에서만 되는 설정이라
자동화할 수 없다. 켠 뒤 Enter를 누르면 나머지가 이어서 진행된다.

`setup.sh`가 5단계에 걸쳐 하는 일 (자세한 근거는 마스터플랜 §5.1):

| 단계 | 내용 |
|---|---|
| 1 | SSH 키 접속 확인 후 비밀번호 로그인 차단, `ufw` 기본 정책만 설정 |
| 2 | Tailscale 설치·인증, `tailscale cert`로 HTTPS 인증서 발급 |
| 3 | Docker 설치, `.env`에 `TAILSCALE_IP`·`HOMECAM_PORT` 기록(포트 충돌 시 여기서 중단), `mediamtx.yml` 최초 배치 |
| 4 | `Caddyfile`을 실제 호스트명·포트로 치환, `docker compose up -d`로 컨테이너 기동 |
| 5 | `ufw` 최종 잠금 (Tailscale UDP 41641만 인바운드 허용 — 포트와 무관하게 인터페이스 전체를 허용하므로 위 포트를 바꿔도 추가 방화벽 조치는 필요 없다) |

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

## 3. 프런트엔드 배포·갱신

최초 배포 시점엔 별도 단계가 없다 — `git clone`한 저장소에 `index.html`·
`camera.html`이 이미 들어있고, `docker compose up -d`(§1) 때 Caddy 컨테이너가
그 두 파일을 저장소 경로에서 직접 바인드 마운트해 곧바로 서빙한다.

이후 로컬에서 두 파일 중 하나를 고쳐서 GitHub에 푸시했다면, VPS에서는 이것만
하면 된다:

```bash
ssh user@vps
cd ~/home-cam && git pull
```

**컨테이너 재시작도 필요 없다** — 정적 파일이라 Caddy가 요청마다 디스크에서
새로 읽는다. 반영됐는지는 브라우저에서 강력 새로고침(iOS Safari는 캐시를
길게 들고 있을 수 있으니 설정 화면을 리셋하거나 캐시 무효화 쿼리스트링으로
확인) 후 접속 화면(§4)으로 확인한다.

## 4. 접속 확인

| 기기 | URL |
|---|---|
| 카메라(구형 안드로이드, Chrome) | `https://<호스트>[:포트]/camera.html#cam=livingroom&pin=<게시PIN>` |
| 뷰어(아이폰·가족 기기) | `https://<호스트>[:포트]/#cam=livingroom&pin=<시청PIN>` |

`[:포트]`는 `setup.sh`에 기본값 443 대신 다른 포트를 지정했을 때만 붙인다
(예: `:8443`) — `setup.sh`가 배포 완료 시 정확한 URL을 그대로 출력해준다.

마스터플랜 §6 Phase 1~2 순서대로: 먼저 PC 브라우저 두 탭으로 왕복 확인 →
실제 구형 폰으로 송출 → LTE 아이폰으로 시청.

**연결되는데 화면이 검게만 나오면** 거의 항상 코덱 불일치다(§2.1, §7 최빈 원인) —
서버 설정이 아니라 두 프런트엔드 파일이 최신 버전인지부터 확인한다.

## 5. 운영 중 점검 명령

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

## 6. 방화벽 확인

`setup.sh`가 마지막 단계에서 UFW를 잠근다. 배포 후 반드시 확인:

```bash
sudo ufw status verbose
# 기대 결과: 41641/udp(Tailscale)만 허용, 그 외 incoming 전체 거부.
# 사용 중인 홈캠 포트(기본 443, 아니면 setup.sh에 지정한 값)가 이 목록에
# 없어야 정상이다 — Caddy 컨테이너는 Tailscale IP에만 바인딩되어 있어야 한다
# (docker-compose.yml의 "${TAILSCALE_IP}:${HOMECAM_PORT}:${HOMECAM_PORT}").

# Docker가 ufw를 우회해 공인 인터넷에 열어버리지 않았는지 직접 확인
# (아래 <포트>는 setup.sh에 준 값, 기본 443):
sudo ss -tlnp | grep :<포트>
# 기대 결과: "100.x.x.x:<포트>"처럼 Tailscale IP 하나만 보여야 한다.
# "0.0.0.0:<포트>"가 보이면 docker-compose.yml의 ports 바인딩이 잘못된 것이다.
```

Oracle Cloud 등 클라우드 VPS라면 여기에 더해 §0에서 설정한 VCN Security
List도 다시 한번 확인한다 — `ufw`는 VM 안쪽만 보고, VCN은 그 바깥을 본다.

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

문제가 생기면 먼저 마스터플랜 §7 장애 조치 매트릭스를 확인한다 — 이 문서에
없는 증상/원인/조치 목록이 정리돼 있다.
