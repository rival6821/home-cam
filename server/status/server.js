'use strict';
///////////////////////////////////////////////////////////////////////////////
// 카메라 상태 릴레이 — 송출 폰의 배터리 상태를 뷰어에게 전달한다.
//
// MediaMTX는 영상·음성만 중계하고 임의 데이터(DataChannel 등)는 넘기지 않으므로,
// 카메라가 주기적으로 올린 배터리 값을 메모리에 들고 있다가 뷰어에게 돌려주는
// 아주 작은 별도 서비스다. Caddy가 /<path>/status 요청만 여기로 프록시한다.
//
//   POST /<path>/status   카메라 → {"level":0~1, "charging":bool}
//   GET  /<path>/status   뷰어   → {"level", "charging", "age"(초)} 또는 404(보고 없음)
//
// 인증은 이 서비스가 직접 하지 않고 MediaMTX에 위임한다 — 요청의 Authorization
// 헤더를 그대로 MediaMTX의 OPTIONS /<path>/whip(게시 권한) 또는 /<path>/whep
// (읽기 권한)에 보내 204면 통과, 401이면 거부한다. 그래서 PIN의 원본은
// mediamtx.yml 하나뿐이고 여기에 복제할 필요가 없다. 잘못된 PIN에 대한
// MediaMTX의 2초 지연(무차별 대입 완화)도 그대로 이어받는다.
//
// §1.5 무저장 원칙: 값은 메모리에만 두며 디스크에 쓰지 않는다. 재시작하면
// 사라지지만 카메라가 1분 안에 다시 보고한다.
//
// 외부 의존성 없음(Node 표준 라이브러리만) — 빌드 단계 없이 공식 node 이미지에
// 이 파일 하나만 마운트해 실행한다(docker-compose.yml 참고).
///////////////////////////////////////////////////////////////////////////////

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8890);
const MEDIAMTX_URL = (process.env.MEDIAMTX_URL || 'http://mediamtx:8889').replace(/\/+$/, '');
const ROUTE_RE = /^\/([A-Za-z0-9_-]{1,32})\/status$/; // §4.2 ASCII 화이트리스트 — 프런트엔드와 동일
const MAX_BODY = 1024;
const AUTH_CACHE_TTL = 5 * 60_000;   // 통과한 인증만 캐시 — 폴링마다 MediaMTX를 두드리지 않도록
const AUTH_TIMEOUT = 8_000;          // MediaMTX의 실패 지연(2초)보다 넉넉하게

const statuses = new Map();  // path → { level, charging, updatedAt }
const authCache = new Map(); // sha256(action|path|Authorization) → 만료 시각

function send(res, code, body){
  const payload = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...(code === 413 ? { Connection: 'close' } : {}),
  });
  res.end(payload);
}

async function authorize(action, path, authHeader){
  if (!authHeader || !/^Basic /i.test(authHeader)) return false;
  const key = crypto.createHash('sha256').update(`${action}|${path}|${authHeader}`).digest('hex');
  const now = Date.now();
  const cached = authCache.get(key);
  if (cached && cached > now) return true;

  // 게시 권한은 whip, 읽기 권한은 whep 엔드포인트로 확인한다 — mediamtx.yml의
  // cam-<경로>(publish)·family-viewer(read) 권한 구분이 그대로 적용된다.
  const endpoint = action === 'publish' ? 'whip' : 'whep';
  try {
    const r = await fetch(`${MEDIAMTX_URL}/${path}/${endpoint}`, {
      method: 'OPTIONS',
      headers: { Authorization: authHeader },
      signal: AbortSignal.timeout(AUTH_TIMEOUT),
    });
    if (r.status === 204 || r.status === 200) {
      authCache.set(key, now + AUTH_CACHE_TTL);
      return true;
    }
    return false;
  } catch (e) {
    console.warn(`[status] MediaMTX 인증 확인 실패: ${e.message}`);
    throw e;
  }
}

function readBody(req){
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY) {
        // 연결을 바로 끊으면 클라이언트가 413을 못 받는다 — 나머지는 읽어 버리고 응답한다.
        req.removeAllListeners('data');
        req.resume();
        reject(Object.assign(new Error('too large'), { code: 413 }));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function parseReport(text){
  let data;
  try { data = JSON.parse(text); } catch (e) { return null; }
  if (!data || typeof data !== 'object') return null;
  const { level, charging } = data;
  if (typeof level !== 'number' || !Number.isFinite(level) || level < 0 || level > 1) return null;
  if (typeof charging !== 'boolean') return null;
  return { level, charging };
}

const server = http.createServer(async (req, res) => {
  const m = ROUTE_RE.exec(new URL(req.url, 'http://x').pathname);
  if (!m) return send(res, 404, { error: 'not found' });
  const path = m[1];

  if (req.method !== 'GET' && req.method !== 'POST') {
    res.setHeader('Allow', 'GET, POST');
    return send(res, 405, { error: 'method not allowed' });
  }

  const action = req.method === 'POST' ? 'publish' : 'read';
  try {
    if (!(await authorize(action, path, req.headers.authorization))) {
      return send(res, 401, { error: 'unauthorized' });
    }
  } catch (e) {
    return send(res, 502, { error: 'auth backend unavailable' });
  }

  if (req.method === 'POST') {
    let report;
    try { report = parseReport(await readBody(req)); }
    catch (e) { return send(res, e.code === 413 ? 413 : 400, { error: 'bad request' }); }
    if (!report) return send(res, 400, { error: 'invalid report' });
    statuses.set(path, { ...report, updatedAt: Date.now() });
    res.writeHead(204, { 'Cache-Control': 'no-store' });
    return res.end();
  }

  const s = statuses.get(path);
  if (!s) return send(res, 404, { error: 'no report' });
  // 경과 시간은 서버 시계로 계산해 준다 — 카메라·뷰어 기기의 시계 오차와 무관하게
  // "마지막 보고가 몇 분 전인지"를 정확히 보여주기 위해서다.
  send(res, 200, { level: s.level, charging: s.charging, age: Math.round((Date.now() - s.updatedAt) / 1000) });
});

// 만료된 인증 캐시 정리(메모리가 쌓이지 않도록)
setInterval(() => {
  const now = Date.now();
  for (const [k, exp] of authCache) if (exp <= now) authCache.delete(k);
}, AUTH_CACHE_TTL).unref();

server.listen(PORT, () => console.log(`[status] listening on :${PORT}, auth via ${MEDIAMTX_URL}`));
// 컨테이너의 PID 1이라 신호 기본 처리가 없다 — 직접 받아 즉시 종료(보관할 상태가 없다)
process.on('SIGTERM', () => process.exit(0));
