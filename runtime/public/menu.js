// One table drives both navigations: the terminal sheet lists every entry,
// the bottom bar lists the main ones (`bar: false` keeps the Steuerung page
// reachable via the sheet and spaces.html without crowding the bar).
// `barLabel` shortens an entry where the full label does not fit; `also`
// marks pages on which a tab stays highlighted (sessions → Chat,
// spacectl → Spaces).
const NAV = [
  { key: 'chat',     href: '/',              icon: '💬', label: 'Chat', also: ['sessions'] },
  { key: 'remote',   href: '/remote.html',   icon: '⌁',  label: 'Remote' },
  { key: 'term',     href: '/terminal.html', icon: '>_', label: 'pi CLI (local)', barLabel: 'CLI' },
  { key: 'clients',  href: '/clients.html',  icon: '⊟',  label: 'Clients' },
  { key: 'spaces',   href: '/spaces.html',   icon: '▦',  label: 'Spaces', also: ['spacectl'] },
  { key: 'spacectl', href: '/spacectl.html', icon: '⚙',  label: 'Spaces-Steuerung', bar: false },
  { key: 'keys',     href: '/keys.html',     icon: '⚿',  label: 'Accounts' },
];

// Shared header setup and bottom navigation for every page.
// renderMenu() is called once per page and returns the session token.
export function renderMenu() {
  // On iOS the Node engine runs in-process and child processes are denied:
  // the local pi CLI terminal cannot run. Remote work speaks the pure-JS SSH
  // backend, so Remote/Clients are fine; ssh terminals are reachable via
  // Clients ▸_ and the sheet below. The server injects the flag.
  const ios = window.PI_MOBILE_IOS === 1;
  const worksOnIos = (href) => !ios || href !== '/terminal.html';
  const token = new URLSearchParams(location.search).get('token')
    || localStorage.getItem('pi-token') || '';
  if (token) localStorage.setItem('pi-token', token);

  // strip the token from the visible URL and WebView history
  const params = new URLSearchParams(location.search);
  if (params.has('token')) {
    params.delete('token');
    const rest = params.toString();
    history.replaceState(null, '', `${location.pathname}${rest ? `?${rest}` : ''}${location.hash}`);
  }
  const q = (p) => `${p}?token=${encodeURIComponent(token)}`;

  const bar = document.getElementById('menubar');
  if (!bar) return token;

  // Brand link
  const brand = document.createElement('a');
  brand.id = 'brand';
  brand.href = q('/');
  brand.innerHTML = '<span class="brand-pi">π</span> mobile';
  bar.prepend(brand);

  const page = document.body.dataset.page;

  // ── Terminal page: hamburger → slide-up nav sheet ─────────────────────────
  if (page === 'term') {
    const menuBtn = document.createElement('button');
    menuBtn.id = 'btn-menu';
    menuBtn.title = 'Navigation';
    menuBtn.textContent = '≡';
    menuBtn.style.marginLeft = 'auto';
    bar.appendChild(menuBtn);

    const overlay = document.createElement('div');
    overlay.id = 'nav-sheet-overlay';
    overlay.className = 'hidden';
    const sheet = document.createElement('div');
    sheet.id = 'nav-sheet';
    for (const t of NAV.filter((t) => worksOnIos(t.href))) {
      const a = document.createElement('a');
      a.href = q(t.href);
      a.innerHTML = `<span class="nav-icon">${t.icon}</span>${t.label}`;
      sheet.appendChild(a);
    }
    // SSH target option (the JS backend carries ssh terminals on iOS)
    const sshA = document.createElement('a');
    sshA.href = '#';
    sshA.innerHTML = '<span class="nav-icon">⌁</span>pi CLI (ssh)…';
    sshA.addEventListener('click', (e) => {
      e.preventDefault();
      overlay.classList.add('hidden');
      const target = prompt('SSH target (user@host[:port]):', localStorage.getItem('pi-ssh-target') || '');
      if (!target) return;
      localStorage.setItem('pi-ssh-target', target);
      location.href = `/terminal.html?token=${encodeURIComponent(token)}&ssh=${encodeURIComponent(target)}`;
    });
    sheet.appendChild(sshA);
    const close = document.createElement('span');
    close.id = 'nav-sheet-close';
    close.textContent = '✕  close';
    sheet.appendChild(close);
    overlay.appendChild(sheet);
    document.body.appendChild(overlay);

    const showSheet = () => overlay.classList.remove('hidden');
    const hideSheet = () => overlay.classList.add('hidden');
    menuBtn.addEventListener('click', showSheet);
    close.addEventListener('click', hideSheet);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) hideSheet(); });
    return token;
  }

  // ── All other pages: bottom navigation bar ────────────────────────────────
  const nav = document.createElement('nav');
  nav.id = 'bottom-nav';
  for (const t of NAV.filter((t) => t.bar !== false && worksOnIos(t.href))) {
    const a = document.createElement('a');
    a.href = q(t.href);
    if (t.key === page || (t.also ?? []).includes(page)) a.className = 'active';
    a.innerHTML = `<span class="nav-icon">${t.icon}</span><span class="nav-label">${t.barLabel || t.label}</span>`;
    nav.appendChild(a);
  }
  document.body.appendChild(nav);
  return token;
}
