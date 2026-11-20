(() => {
  const tokenMeta = document.querySelector('meta[name="parfait-workbench-token"]');
  const token = tokenMeta ? tokenMeta.getAttribute('content') : '';

  const els = {
    serverOrigin: document.getElementById('server-origin'),
    gatewayCount: document.getElementById('gateway-count'),
    clientsList: document.getElementById('clients-list'),
    targetClient: document.getElementById('target-client'),
    customRoute: document.getElementById('custom-route'),
    boundsKind: document.getElementById('bounds-kind'),
    boundsQuery: document.getElementById('bounds-query'),
    cmdOut: document.getElementById('command-output'),
    faultPrefix: document.getElementById('fault-prefix'),
    faultMode: document.getElementById('fault-mode'),
    faultsBox: document.getElementById('faults-box'),
    logsBox: document.getElementById('logs-box'),
    artifactsGrid: document.getElementById('artifacts-grid'),
  };

  let latestClients = [];
  let lastArtifactsSignature = null;

  async function postJson(url, body) {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Parfait-Workbench-Token': token || '',
      },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) {
      throw new Error(data.error || `HTTP ${res.status}`);
    }
    return data;
  }

  function selectedClientId() {
    return els.targetClient.value;
  }

  async function sendCommand(type, args = {}) {
    const clientId = selectedClientId();
    if (!clientId) {
      els.cmdOut.textContent = '暂无在线客户端，无法发送命令';
      return;
    }
    try {
      const resp = await postJson('/api/commands', { clientId, type, args });
      els.cmdOut.textContent = `已入队 ${type} (${resp.id})`;
      await refreshState();
    } catch (err) {
      els.cmdOut.textContent = `命令失败: ${err.message}`;
    }
  }

  function isAllowedLoopbackUrl(raw) {
    if (!raw || typeof raw !== 'string') return false;
    try {
      const parsed = new URL(raw);
      const host = (parsed.hostname || '').toLowerCase();
      return parsed.protocol === 'http:' &&
        (host === '127.0.0.1' || host === 'localhost' || host === '::1' || host === '[::1]' || host === '10.0.2.2');
    } catch (_) {
      return false;
    }
  }

  function resolveLoopbackOriginForClient(clientId) {
    const client = latestClients.find((c) => c.clientId === clientId);
    const current = client && client.snapshot ? client.snapshot.loopbackOrigin : null;
    if (isAllowedLoopbackUrl(current)) {
      return current;
    }
    return els.serverOrigin.textContent;
  }

  function renderClients(clients) {
    latestClients = clients;
    const prev = els.targetClient.value;
    els.targetClient.innerHTML = '';
    if (!clients.length) {
      els.clientsList.textContent = '暂无连接客户端（请带 --workbench-url 启动）';
      return;
    }
    els.clientsList.textContent = '';
    for (const c of clients) {
      const opt = document.createElement('option');
      opt.value = c.clientId;
      opt.textContent = `${c.platform} | ${c.clientId}`;
      els.targetClient.appendChild(opt);

      const card = document.createElement('div');
      card.className = 'client-card';
      const s = c.snapshot || {};
      const vp = s.viewport || {};
      const fp = s.frameProbe || {};
      const lines = [
        `${c.clientId} (${c.platform}) — ${c.online ? '在线' : '离线'} (${c.ageSeconds}s)`,
        `数据源: ${s.sourceMode || '-'} | 路由: ${s.uri || s.route || '-'}`,
        `视口: ${vp.width || 0}x${vp.height || 0} @${vp.dpr || 1}x | 隔离存储: ${Boolean(s.isDevIsolated)}`,
        `登录态: ${Boolean(s.hasUsableAccount)} | 帧探针 frames=${fp.frameCount || 0} | ImageWorker=${(s.imageWorker && s.imageWorker.state) || '-'}`,
      ];
      card.textContent = lines.join('\n');
      els.clientsList.appendChild(card);
    }
    if ([...els.targetClient.options].some((o) => o.value === prev)) {
      els.targetClient.value = prev;
    }
  }

  function renderArtifacts(artifacts) {
    const signature = JSON.stringify(
      artifacts.map((a) => [a.name, a.size, a.url, a.ext])
    );
    if (signature === lastArtifactsSignature) {
      return;
    }
    lastArtifactsSignature = signature;
    if (!artifacts.length) {
      els.artifactsGrid.textContent = '暂未挂载或无录制产物';
      return;
    }
    els.artifactsGrid.textContent = '';
    for (const item of artifacts) {
      const card = document.createElement('div');
      card.className = 'artifact-card';
      if (item.ext === '.gif' || item.ext === '.png' || item.ext === '.jpg' || item.ext === '.webp') {
        const img = document.createElement('img');
        img.src = item.url;
        img.alt = item.name;
        card.appendChild(img);
      } else if (item.ext === '.mp4' || item.ext === '.webm') {
        const video = document.createElement('video');
        video.src = item.url;
        video.controls = true;
        video.loop = true;
        video.muted = true;
        video.playsInline = true;
        video.preload = 'metadata';
        card.appendChild(video);
      }
      const label = document.createElement('div');
      label.textContent = `${item.name} (${item.size} B)`;
      card.appendChild(label);
      els.artifactsGrid.appendChild(card);
    }
  }

  async function refreshState() {
    try {
      const res = await fetch('/api/state', { cache: 'no-store' });
      const state = await res.json();
      els.serverOrigin.textContent = state.server.loopbackOrigin;
      els.gatewayCount.textContent = `Gateway: ${state.server.gatewayCount}`;
      renderClients(state.clients || []);
      els.faultsBox.textContent = JSON.stringify(state.faults || {}, null, 2);

      const lines = [];
      for (const r of (state.commandResults || []).slice(0, 6)) {
        lines.push(`[CMD ${r.ok ? 'OK' : 'ERR'}] ${r.id}: ${JSON.stringify(r.result || r.error)}`);
      }
      for (const t of (state.traces || []).slice(-12).reverse()) {
        lines.push(`[GW #${t.seq}] ${t.status} ${t.method} ${t.targetHost}${t.path} (fault=${t.fault})`);
      }
      for (const l of (state.logs || []).slice(-25).reverse()) {
        lines.push(`[${l.level || 'info'}:${l.source || 'app'}] ${l.message}`);
      }
      els.logsBox.textContent = lines.join('\n') || '暂无日志';
      renderArtifacts(state.artifacts || []);
    } catch (_) {
      // Ignore transient poll failure while server restarts.
    }
  }

  document.querySelectorAll('[data-cmd]').forEach((btn) => {
    btn.addEventListener('click', () => sendCommand(btn.getAttribute('data-cmd')));
  });
  document.querySelectorAll('[data-source]').forEach((btn) => {
    btn.addEventListener('click', () =>
      sendCommand('setSourceMode', {
        mode: btn.getAttribute('data-source'),
        loopbackOrigin: resolveLoopbackOriginForClient(selectedClientId()),
      })
    );
  });
  document.querySelectorAll('[data-nav]').forEach((btn) => {
    btn.addEventListener('click', () =>
      sendCommand('navigate', { path: btn.getAttribute('data-nav') })
    );
  });
  document.querySelectorAll('[data-history]').forEach((btn) => {
    btn.addEventListener('click', () =>
      sendCommand('history', { action: btn.getAttribute('data-history') })
    );
  });
  document.querySelectorAll('[data-size]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const [w, h] = btn.getAttribute('data-size').split('x').map(Number);
      sendCommand('resizeWindow', { width: w, height: h });
    });
  });

  document.getElementById('btn-go-route').addEventListener('click', () => {
    const path = (els.customRoute.value || '').trim();
    if (path) sendCommand('navigate', { path });
  });
  document.getElementById('btn-find-bounds').addEventListener('click', () => {
    const kind = els.boundsKind.value;
    const query = (els.boundsQuery.value || '').trim();
    if (query) sendCommand('findBounds', { kind, query });
  });
  document.getElementById('btn-apply-fault').addEventListener('click', async () => {
    try {
      await postJson('/api/faults', {
        routePrefix: els.faultPrefix.value.trim(),
        mode: els.faultMode.value,
      });
      await refreshState();
    } catch (err) {
      els.cmdOut.textContent = `故障注入失败: ${err.message}`;
    }
  });
  document.getElementById('btn-reset-faults').addEventListener('click', async () => {
    try {
      await postJson('/api/faults', { reset: true });
      await refreshState();
    } catch (err) {
      els.cmdOut.textContent = `重置故障失败: ${err.message}`;
    }
  });

  refreshState();
  setInterval(refreshState, 1200);
})();
