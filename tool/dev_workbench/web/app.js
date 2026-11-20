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
    manifestSummary: document.getElementById('manifest-summary'),
    coverageGapsBox: document.getElementById('coverage-gaps-box'),
    filterPlatform: document.getElementById('filter-platform'),
    filterEvidence: document.getElementById('filter-evidence'),
    filterStatus: document.getElementById('filter-status'),
    filterModule: document.getElementById('filter-module'),
    filterDirection: document.getElementById('filter-direction'),
    filterMotion: document.getElementById('filter-motion'),
    filterSearch: document.getElementById('filter-search'),
    toggleCompare: document.getElementById('toggle-compare'),
    toggleSheets: document.getElementById('toggle-sheets'),
  };

  let latestClients = [];
  let lastRawArtifacts = [];
  let lastArtifactsSignature = null;
  let lastManifestSignature = null;
  let manifestPayload = null;

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

  function makeBadge(text, cls) {
    const span = document.createElement('span');
    span.className = `badge ${cls}`;
    span.textContent = text;
    return span;
  }

  function buildRecordCard(rec) {
    const card = document.createElement('div');
    card.className = 'artifact-card';
    if (rec.status === 'recorded_with_anomaly') card.classList.add('is-anomaly');
    if (rec.status === 'failed') card.classList.add('is-failed');

    const badges = document.createElement('div');
    badges.className = 'badge-row';
    badges.appendChild(makeBadge(rec.platform, 'badge-muted'));
    if (rec.evidence_kind === 'native_os_recording') {
      badges.appendChild(makeBadge('真实 OS 实录', 'badge-real'));
    } else if (rec.evidence_kind === 'widget_tester_simulation') {
      badges.appendChild(makeBadge('WidgetTester 框架模拟', 'badge-sim'));
    } else {
      badges.appendChild(makeBadge(rec.evidence_kind || 'other', 'badge-muted'));
    }
    if (rec.status === 'recorded_with_anomaly') {
      badges.appendChild(makeBadge('异常实录', 'badge-anomaly'));
    } else if (rec.status === 'failed') {
      badges.appendChild(makeBadge('失败', 'badge-fail'));
    } else if (rec.status !== 'ok') {
      badges.appendChild(makeBadge(rec.status, 'badge-muted'));
    }
    if (rec.audit_candidate) {
      badges.appendChild(makeBadge(rec.audit_candidate, 'badge-anomaly'));
    }
    const mm = rec.motion_metrics && typeof rec.motion_metrics === 'object' ? rec.motion_metrics : null;
    const motionFlags = mm && Array.isArray(mm.motion_flags) ? mm.motion_flags : [];
    for (const flag of motionFlags) {
      badges.appendChild(makeBadge(flag, 'badge-motion'));
    }
    card.appendChild(badges);

    const sheetUrls = Array.isArray(rec.sheetUrls) ? rec.sheetUrls : [];
    if (rec.artifactUrl || sheetUrls.length) {
      const mediaSlot = document.createElement('div');
      mediaSlot.className = 'media-slot';
      let showSheet = Boolean(els.toggleSheets && els.toggleSheets.checked && sheetUrls.length);

      const renderSlot = () => {
        mediaSlot.textContent = '';
        if (showSheet && sheetUrls.length) {
          for (let i = 0; i < sheetUrls.length; i++) {
            const link = document.createElement('a');
            link.href = sheetUrls[i];
            link.target = '_blank';
            link.rel = 'noopener noreferrer';
            const img = document.createElement('img');
            img.src = sheetUrls[i];
            img.alt = `${rec.catalog_id} storyboard sheet ${i + 1}/${sheetUrls.length}`;
            img.loading = 'lazy';
            link.appendChild(img);
            mediaSlot.appendChild(link);
          }
        } else if (rec.artifactUrl) {
          if (rec.format === 'mp4') {
            const video = document.createElement('video');
            video.src = rec.artifactUrl;
            video.controls = true;
            video.loop = true;
            video.muted = true;
            video.playsInline = true;
            video.preload = 'metadata';
            mediaSlot.appendChild(video);
          } else {
            const img = document.createElement('img');
            img.src = rec.artifactUrl;
            img.alt = rec.catalog_id;
            img.loading = 'lazy';
            mediaSlot.appendChild(img);
          }
        }
      };

      renderSlot();
      card.appendChild(mediaSlot);

      if (rec.artifactUrl && sheetUrls.length) {
        const toggleBtn = document.createElement('button');
        toggleBtn.type = 'button';
        toggleBtn.className = 'btn-secondary btn-mini';
        const syncLabel = () => {
          toggleBtn.textContent = showSheet ? '切回原视频/GIF' : `看拼版 Sheet (${sheetUrls.length})`;
        };
        syncLabel();
        toggleBtn.addEventListener('click', () => {
          showSheet = !showSheet;
          renderSlot();
          syncLabel();
        });
        card.appendChild(toggleBtn);
      }
    }

    const title = document.createElement('div');
    title.textContent = `${rec.catalog_id} [${rec.direction || '-'}]`;
    card.appendChild(title);

    const meta = document.createElement('div');
    meta.className = 'diag-note';
    const parts = [`mode=${rec.capture_mode || '-'}`];
    if (rec.bytes) parts.push(`${rec.width || 0}x${rec.height || 0} (${rec.bytes} B)`);
    if (rec.route_before || rec.route_after) parts.push(`${rec.route_before || '?'} → ${rec.route_after || '?'}`);
    if (mm) parts.push(`frames=${mm.frame_count || 0} Δmax=${mm.max_change_pct ?? 0}% end=${mm.start_end_diff_pct ?? 0}%`);
    meta.textContent = parts.join(' | ');
    card.appendChild(meta);

    if (Array.isArray(rec.known_blind_spots) && rec.known_blind_spots.length) {
      const blind = document.createElement('div');
      blind.className = 'diag-note';
      blind.textContent = `已知模拟/捕获盲区: ${rec.known_blind_spots.join(', ')}`;
      card.appendChild(blind);
    }

    const diag = rec.diagnostics || {};
    if (Object.keys(diag).length) {
      const diagEl = document.createElement('div');
      diagEl.className = 'diag-note';
      diagEl.textContent = JSON.stringify(diag);
      card.appendChild(diagEl);
    }
    return card;
  }

  function renderManifestGallery(fallbackArtifacts) {
    if (!manifestPayload || !manifestPayload.hasManifest) {
      renderRawArtifacts(fallbackArtifacts || lastRawArtifacts);
      return;
    }
    lastArtifactsSignature = null;
    const allRecs = manifestPayload.records || [];
    const rep = manifestPayload.report || {};
    const pfCount = Object.entries(rep.per_platform || {})
      .map(([p, b]) => `${p}: ok=${b.ok || 0}, anom=${b.recorded_with_anomaly || 0}, fail=${b.failed || 0}`)
      .join(' | ');
    els.manifestSummary.textContent =
      `Run ${manifestPayload.runId || '-'} (${manifestPayload.gitHead || '-'}) | ` +
      `异常=${rep.anomalies_count || 0}, 失败=${rep.failures_count || 0}, 动效疑点=${rep.motion_anomalies_count || 0}` +
      (pfCount ? ` | ${pfCount}` : '');

    // Populate module options once
    const prevMod = els.filterModule.value;
    const mods = [...new Set(allRecs.map((r) => r.module).filter(Boolean))].sort();
    els.filterModule.innerHTML = '<option value="all">全部模块</option>';
    for (const m of mods) {
      const opt = document.createElement('option');
      opt.value = m;
      opt.textContent = m;
      els.filterModule.appendChild(opt);
    }
    if (mods.includes(prevMod)) els.filterModule.value = prevMod;

    // Show gaps / audit candidates summary
    const gapLines = [];
    for (const [cand, list] of Object.entries(rep.audit_candidates || {})) {
      for (const row of list) {
        gapLines.push(`[${cand}] ${row.platform}/${row.catalog_id} -> ${row.status} ${JSON.stringify(row.diagnostics || {})}`);
      }
    }
    for (const a of (rep.anomalies || []).slice(0, 10)) {
      gapLines.push(`[ANOMALY] ${a.platform}/${a.catalog_id}: ${JSON.stringify(a.diagnostics || {})}`);
    }
    for (const m of (rep.motion_anomalies || []).slice(0, 12)) {
      gapLines.push(`[MOTION] ${m.platform}/${m.catalog_id}: flags=${(m.motion_flags || []).join(',')} Δmax=${m.max_change_pct}% end=${m.start_end_diff_pct}%`);
    }
    if (gapLines.length) {
      els.coverageGapsBox.classList.remove('hidden');
      els.coverageGapsBox.textContent = gapLines.join('\n');
    } else {
      els.coverageGapsBox.classList.add('hidden');
    }

    const fp = els.filterPlatform.value;
    const fe = els.filterEvidence.value;
    const fs = els.filterStatus.value;
    const fm = els.filterModule.value;
    const fd = els.filterDirection.value;
    const fmot = els.filterMotion ? els.filterMotion.value : 'all';
    const fq = (els.filterSearch.value || '').trim().toLowerCase();

    const filtered = allRecs.filter((r) => {
      if (fp !== 'all' && r.platform !== fp) return false;
      if (fe !== 'all' && r.evidence_kind !== fe) return false;
      if (fs !== 'all' && r.status !== fs) return false;
      if (fm !== 'all' && r.module !== fm) return false;
      if (fd !== 'all' && r.direction !== fd) return false;
      if (fmot === 'flagged') {
        const flags = r.motion_metrics && Array.isArray(r.motion_metrics.motion_flags) ? r.motion_metrics.motion_flags : [];
        if (!flags.length) return false;
      }
      if (fq) {
        const hay = `${r.catalog_id} ${r.route_template || ''} ${r.audit_candidate || ''} ${r.module || ''}`.toLowerCase();
        if (!hay.includes(fq)) return false;
      }
      return true;
    });

    els.artifactsGrid.textContent = '';
    if (!filtered.length) {
      els.artifactsGrid.className = 'artifacts-grid';
      els.artifactsGrid.textContent = '当前筛选条件无匹配条目';
      return;
    }

    if (els.toggleCompare.checked) {
      els.artifactsGrid.className = 'compare-groups';
      const byId = new Map();
      for (const rec of filtered) {
        if (!byId.has(rec.catalog_id)) byId.set(rec.catalog_id, []);
        byId.get(rec.catalog_id).push(rec);
      }
      for (const [cid, rows] of byId.entries()) {
        const group = document.createElement('div');
        group.className = 'compare-row';
        const hdr = document.createElement('div');
        hdr.className = 'compare-row-header';
        const first = rows[0] || {};
        hdr.textContent = `${cid}  (${first.module || '-'} · ${first.route_template || first.shell_layer || '-'} · ${first.direction || '-'})`;
        group.appendChild(hdr);
        const cells = document.createElement('div');
        cells.className = 'compare-cells';
        for (const r of rows) {
          cells.appendChild(buildRecordCard(r));
        }
        group.appendChild(cells);
        els.artifactsGrid.appendChild(group);
      }
    } else {
      els.artifactsGrid.className = 'artifacts-grid';
      for (const r of filtered) {
        els.artifactsGrid.appendChild(buildRecordCard(r));
      }
    }
  }

  function renderRawArtifacts(artifacts) {
    const signature = JSON.stringify(artifacts.map((a) => [a.name, a.size, a.url, a.ext]));
    if (signature === lastArtifactsSignature) return;
    lastArtifactsSignature = signature;
    els.manifestSummary.textContent = '未检测到 catalog manifest.json，回退显示原始文件目录';
    els.artifactsGrid.className = 'artifacts-grid';
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
      const [stateRes, manRes] = await Promise.all([
        fetch('/api/state', { cache: 'no-store' }),
        fetch('/api/catalog-manifest', { cache: 'no-store' }),
      ]);
      const state = await stateRes.json();
      const man = await manRes.json();
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

      lastRawArtifacts = state.artifacts || [];
      const manSig = JSON.stringify([
        Boolean(man.hasManifest),
        man.runId,
        man.generatedAt,
        (man.records || []).length,
        man.report ? man.report.motion_anomalies_count || 0 : 0,
      ]);
      if (manSig !== lastManifestSignature) {
        lastManifestSignature = manSig;
        manifestPayload = man;
        renderManifestGallery(lastRawArtifacts);
      } else if (!man.hasManifest) {
        renderRawArtifacts(lastRawArtifacts);
      }
    } catch (_) {
      // Ignore transient poll failure while server restarts.
    }
  }

  for (const el of [
    els.filterPlatform,
    els.filterEvidence,
    els.filterStatus,
    els.filterModule,
    els.filterDirection,
    els.filterMotion,
    els.toggleCompare,
    els.toggleSheets,
  ]) {
    if (el) el.addEventListener('change', () => renderManifestGallery(lastRawArtifacts));
  }
  els.filterSearch.addEventListener('input', () => renderManifestGallery(lastRawArtifacts));

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
