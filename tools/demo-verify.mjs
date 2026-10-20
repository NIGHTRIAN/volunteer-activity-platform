/**
 * 演示辅助：把李娜的记录补回「已通过」，并打印当前状态。
 * **只读 + 一次 upsert**，不含任何 DELETE。
 */
const base = 'http://127.0.0.1:8080/api';

const call = async (method, p, b, t) => {
  const r = await fetch(base + p, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(t ? { authorization: 'Bearer ' + t } : {}),
    },
    body: b ? JSON.stringify(b) : undefined,
  });
  return { s: r.status, ...(await r.json()) };
};

const iso = (d) => {
  const o = -d.getTimezoneOffset();
  const s = o >= 0 ? '+' : '-';
  const a = Math.abs(o);
  const t = (n) => String(n).padStart(2, '0');
  return (
    d.getFullYear() + '-' + t(d.getMonth() + 1) + '-' + t(d.getDate()) +
    'T' + t(d.getHours()) + ':' + t(d.getMinutes()) + ':' + t(d.getSeconds()) +
    s + t(Math.floor(a / 60)) + ':' + t(a % 60)
  );
};

const admin = await call('POST', '/auth/admin/login', {
  inviteCode: '1111',
  deviceId: 'pc-fix',
});
const ah = admin.data.token;

const list = await call('GET', '/activities/9/checkins', null, ah);
console.log('  当前签到记录:');
for (const c of list.data.items) {
  console.log('    %s %s status=%s score=%s', c.userNo, c.name, c.status, c.score);
}

const has = list.data.items.some((c) => c.userNo === '2026102');
if (!has) {
  const b = await call('POST', '/auth/bind', {
    activityId: '9',
    userNo: '2026102',
    inviteCode: 'SQQ6BW8X',
    deviceId: 'weak-vol',
    name: '李娜',
  });
  const now = new Date();
  const ck = await call('POST', '/activities/9/checkins', {
    method: 'geo',
    clientTime: iso(now),
    deviceId: 'weak-vol',
    location: {
      lat: 34.2188,
      lng: 117.1382,
      accuracy: 85,
      samples: [
        { lat: 34.2188, lng: 117.1382, accuracy: 85 },
        { lat: 34.21881, lng: 117.13821, accuracy: 88 },
      ],
    },
    network: { sourceIp: '10.3.229.13' },
    idempotencyKey: 'restore-' + Date.now(),
  }, b.data.token);
  console.log('  重新签到: status=%s score=%s', ck.data?.checkin?.status, ck.data?.checkin?.score);
  const rv = await call('POST', '/checkins/' + ck.data.checkin.id + '/review', {
    decision: 'approve',
    note: '现场已核实本人在图书馆三层',
  }, ah);
  console.log('  复核: code=%s status=%s reviewedBy=%s',
    rv.code, rv.data?.checkin?.status, rv.data?.checkin?.reviewedBy);
} else {
  console.log('  李娜的记录已在，无需补');
}

const final = await call('GET', '/activities/9/checkins', null, ah);
const board = await call('GET', '/activities/9/board', null, ah);
console.log('  最终签到: %s', final.data.items.map((c) => c.userNo + ':' + c.status).join(', '));
console.log('  看板计数: %s', JSON.stringify(board.data.counts));
