(function () {
  const cfg = window.RHEL_CONFIG;
  if (!cfg) return;

  const fmt = n => Number(n || 0).toLocaleString('en-US');
  const pct = (value, total) => total > 0 ? Math.min(100, Math.max(0, value / total * 100)) : 0;

  document.querySelectorAll('[data-site-title]').forEach(el => el.textContent = cfg.site.title);
  document.querySelectorAll('[data-site-subtitle]').forEach(el => el.textContent = cfg.site.subtitle);
  document.querySelectorAll('[data-site-org]').forEach(el => el.textContent = cfg.site.organization);
  document.querySelectorAll('[data-site-updated]').forEach(el => el.textContent = `Updated ${cfg.site.updated}`);

  const external = document.querySelector('[data-external-links]');
  if (external) {
    external.innerHTML = cfg.externalLinks.map(item => `
      <a class="side-link external" href="${item.href}" target="_blank" rel="noopener">
        <span class="nav-icon">↗</span><span>${item.label}</span>
      </a>`).join('');
  }

  const set = (selector, value) => {
    const el = document.querySelector(selector);
    if (el) el.textContent = value;
  };
  set('[data-kpi="virtual"]', fmt(cfg.totals.virtual));
  set('[data-kpi="physical"]', fmt(cfg.totals.physical));
  set('[data-kpi="cloud"]', fmt(cfg.totals.cloud));
  set('[data-kpi="ssh"]', fmt(cfg.totals.sshFailures));

  const majorTotals = cfg.rhelVersions.reduce((acc, item) => {
    acc[item.major] = (acc[item.major] || 0) + item.count;
    return acc;
  }, {});
  const classifiedTotal = Object.values(majorTotals).reduce((a,b) => a+b, 0);

  const donut = document.querySelector('[data-rhel-donut]');
  if (donut) {
    const p8 = pct(majorTotals[8] || 0, classifiedTotal);
    donut.style.background = `conic-gradient(var(--v8) 0 ${p8}%, var(--v9) ${p8}% 100%)`;
    set('[data-classified-total]', fmt(classifiedTotal));
    const legend = document.querySelector('[data-rhel-major-legend]');
    if (legend) legend.innerHTML = [8,9].map(major => `
      <div class="dl-item"><span class="sw" style="background:var(--v${major})"></span>
        <span class="name">RHEL ${major}.x</span>
        <span class="pct">${pct(majorTotals[major] || 0, classifiedTotal).toFixed(1)}%</span>
        <span class="val">${fmt(majorTotals[major] || 0)}</span>
      </div>`).join('');
  }

  function renderBars(selector, rows, total, colorClass, labelPrefix='') {
    const target = document.querySelector(selector);
    if (!target) return;
    target.innerHTML = rows.map(item => `
      <div class="bar">
        <span class="name">${labelPrefix}${item.version || item.name}</span>
        <span class="track"><span class="fill ${item.major ? 'v'+item.major : colorClass}" style="width:${pct(item.count,total).toFixed(2)}%"></span></span>
        <span class="val${item.count === 0 ? ' zero' : ''}">${fmt(item.count)}</span>
      </div>`).join('');
  }

  renderBars('[data-minor-versions]', cfg.rhelVersions, classifiedTotal, '', 'RHEL ');
  renderBars('[data-environments]', cfg.environments, cfg.totals.totalHosts, 'env');
  renderBars('[data-locations]', cfg.locations, cfg.totals.totalHosts, 'loc');

  document.querySelectorAll('[data-latest-inventory]').forEach(a => a.href = cfg.downloads.latestInventoryCsv);
  const history = document.querySelector('[data-history-rows]');
  if (history) {
    history.innerHTML = cfg.historicalFiles.map((f, i) => `
      <tr><td>${i === 0 ? '<span class="latest-tag">Latest</span>' : ''}</td><td class="filename">${f.filename}</td><td>${f.timestamp}</td><td>${f.size}</td><td><a class="download-link" href="${f.href}" download>Download CSV</a></td></tr>`).join('');
  }

  // Host inventory search and filters.
  const inventoryBody = document.getElementById('tb');
  if (inventoryBody) {
    const rows = Array.from(inventoryBody.querySelectorAll('tr')).filter(row => row.querySelectorAll('td').length > 0);
    const locSel = document.getElementById('locF');
    const countBadge = document.getElementById('cb');

    if (locSel) {
      const locations = [...new Set(rows.map(row => {
        const cell = row.querySelectorAll('td')[2];
        return cell ? cell.textContent.trim() : '';
      }).filter(Boolean))].sort();
      locations.forEach(location => {
        const option = document.createElement('option');
        option.value = location;
        option.textContent = location;
        locSel.appendChild(option);
      });
    }

    const updateCount = visible => {
      if (countBadge) countBadge.innerHTML = `Showing <b>${visible}</b> of <b>${rows.length}</b> hosts`;
    };

    window.ft = function () {
      const q = (document.getElementById('search')?.value || '').trim().toLowerCase();
      const env = (document.getElementById('envF')?.value || '').toLowerCase();
      const type = (document.getElementById('typF')?.value || '').toLowerCase();
      const os = (document.getElementById('osF')?.value || '').toLowerCase();
      const location = (document.getElementById('locF')?.value || '').toLowerCase();
      let visible = 0;

      rows.forEach(row => {
        const cells = row.querySelectorAll('td');
        const rowText = row.textContent.toLowerCase();
        const rowType = cells[1]?.textContent.trim().toLowerCase() || '';
        const rowLocation = cells[2]?.textContent.trim().toLowerCase() || '';
        const rowEnvironment = cells[4]?.textContent.trim().toLowerCase() || '';
        const rowOs = cells[6]?.textContent.trim().toLowerCase() || '';

        const show = (!q || rowText.includes(q))
          && (!env || rowEnvironment === env)
          && (!type || rowType === type)
          && (!os || rowOs === os)
          && (!location || rowLocation === location);

        row.hidden = !show;
        if (show) visible += 1;
      });
      updateCount(visible);
    };

    window.ft();
  }

})();
