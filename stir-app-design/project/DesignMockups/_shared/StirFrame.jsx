// StirFrame.jsx — iPhone 16 Pro frame tuned for Stir.
// Deliberately NOT the generic iOS liquid-glass frame — Stir forbids glassmorphism
// (Design-System §1). This frame provides a clean bezel + status bar + home indicator,
// then gets out of the way so Stir's warm paper palette carries the screen.
//
// Width/height: 390 × 844 (scaled iPhone 16 Pro @1x-ish for mockup density).
// Exports: StirFrame, StirStatusBar, StirTabBar, StirDynamicIsland, StirKitPage, SF

const STIR_LIGHT = { bg: '#FAF7F2', paper100: '#F3EEE5', paper200: '#EBE3D6',
  ink900: '#1A1612', ink700: '#3D342C', ink500: '#6B5F54', ink300: '#A89E93',
  ink100: '#E8E3DD', ember: '#C8532B', emberTint: '#FBEAE0', sage: '#4A7C59',
  sageTint: '#E4EEE6', amber: '#B8860B', amberTint: '#F5ECD5',
  crimson: '#9A2E2E', crimsonTint: '#F2DCDC', voice: '#5E4AE0', voiceTint: '#E8E3FA' };

const STIR_DARK = { bg: '#14100B', paper100: '#1F1A14', paper200: '#2A241C',
  ink900: '#F5F0E8', ink700: '#D6CEC3', ink500: '#9A8F84', ink300: '#5E5349',
  ink100: '#2E2822', ember: '#E26340', emberTint: '#3A1E13', sage: '#6FA07C',
  sageTint: '#1E2E23', amber: '#D4A21F', amberTint: '#2E2614',
  crimson: '#C94747', crimsonTint: '#2E1818', voice: '#8473E8', voiceTint: '#1F1A33' };

const useStir = (dark) => dark ? STIR_DARK : STIR_LIGHT;

// Minimal SF-Symbol-ish stand-ins. For real product, these are SF Symbols.
// In HTML mockups, we use simple stroke-width SVG paths matching the weight.
const SF = {
  camera:   (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><rect x="2" y="6" width="20" height="14" rx="2.5"/><circle cx="12" cy="13" r="4"/><path d="M7 6l2-3h6l2 3"/></svg>,
  bookmark: (c, s=20, fill=false) => <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={c} strokeWidth="1.7" strokeLinejoin="round"><path d="M6 3h12v18l-6-4-6 4z"/></svg>,
  gear:     (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19 15l1.5 1-1 2-2-.5M5 15l-1.5 1 1 2 2-.5M19 9l1.5-1-1-2-2 .5M5 9l-1.5-1 1-2 2 .5M12 2v2M12 20v2M2 12h2M20 12h2"/></svg>,
  fork:     (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M6 2v8a2 2 0 002 2v10M10 2v8M6 2h4M18 2c0 4-2 6-2 10v10M18 2s2 2 2 6-2 4-2 4"/></svg>,
  mic:      (c, s=20, fill=false, slash=false) => <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0014 0M12 18v3M8 21h8"/>{slash && <path d="M3 3l18 18" stroke={c} strokeWidth="2"/>}</svg>,
  timer:    (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="13" r="8"/><path d="M12 8v5l3 2M9 2h6"/></svg>,
  cart:     (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M3 4h2l2 13h12M7 17h12l2-9H6"/><circle cx="9" cy="20" r="1.5"/><circle cx="18" cy="20" r="1.5"/></svg>,
  check:    (c, s=16, fill=false) => <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={fill?"#fff":c} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">{fill && <circle cx="12" cy="12" r="10" fill={c} stroke="none"/>}<path d="M7 12l3.5 3.5L17 9"/></svg>,
  question: (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="10"/><path d="M9.5 9a2.5 2.5 0 115 0c0 1.5-2.5 2-2.5 4"/><circle cx="12" cy="17" r="0.8" fill={c}/></svg>,
  warn:     (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill={c}><path d="M12 2L1 21h22L12 2zm0 6v7m0 2v1" stroke="#fff" strokeWidth="1.6" strokeLinecap="round"/></svg>,
  sparkles: (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill={c}><path d="M12 2l1.8 4.2L18 8l-4.2 1.8L12 14l-1.8-4.2L6 8l4.2-1.8zM20 14l.9 2.1L23 17l-2.1.9L20 20l-.9-2.1L17 17l2.1-.9zM5 14l.9 2.1L8 17l-2.1.9L5 20l-.9-2.1L2 17l2.1-.9z"/></svg>,
  heart:    (c, s=20, fill=false) => <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={c} strokeWidth="1.7" strokeLinejoin="round"><path d="M12 21s-8-4.5-8-11a5 5 0 019-3 5 5 0 019 3c0 6.5-8 11-8 11z"/></svg>,
  chevronR: (c, s=14) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M9 6l6 6-6 6"/></svg>,
  chevronL: (c, s=14) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M15 6l-6 6 6 6"/></svg>,
  close:    (c, s=18) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2.2" strokeLinecap="round"><path d="M6 6l12 12M6 18L18 6"/></svg>,
  download: (c, s=20) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3v13m-5-5l5 5 5-5M5 21h14"/></svg>,
  plus:     (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2" strokeLinecap="round"><path d="M12 5v14M5 12h14"/></svg>,
  star:     (c, s=18, fill=false) => <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={c} strokeWidth="1.7" strokeLinejoin="round"><path d="M12 2l3 7 7.5.6-5.7 5 1.8 7.4L12 18l-6.6 4 1.8-7.4-5.7-5L9 9z"/></svg>,
  arrowR:   (c, s=18) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12h14M13 5l7 7-7 7"/></svg>,
  lock:     (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/></svg>,
  wifi:     (c, s=14) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="1.7" strokeLinecap="round"><path d="M2 9c6-6 14-6 20 0M5 13c4.5-4.5 10-4.5 14.5 0M8.5 16.5c2.5-2.5 5-2.5 7.5 0"/><circle cx="12" cy="20" r="1" fill={c}/></svg>,
  info:     (c, s=16) => <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke={c} strokeWidth="2"><circle cx="12" cy="12" r="10"/><path d="M12 11v6M12 7.5v.01" strokeLinecap="round"/></svg>,
};

function StirStatusBar({ dark, time = '7:42' }) {
  const c = dark ? '#F5F0E8' : '#1A1612';
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      padding: '14px 28px 6px', fontFamily: '-apple-system, "SF Pro Text", system-ui',
      fontWeight: 600, fontSize: 15, color: c, height: 44, boxSizing: 'border-box' }}>
      <span style={{ letterSpacing: 0.2 }}>{time}</span>
      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
        {/* signal bars */}
        <svg width="16" height="10" viewBox="0 0 16 10"><rect x="0" y="7" width="2.5" height="3" rx="0.5" fill={c}/><rect x="4" y="5" width="2.5" height="5" rx="0.5" fill={c}/><rect x="8" y="3" width="2.5" height="7" rx="0.5" fill={c}/><rect x="12" y="1" width="2.5" height="9" rx="0.5" fill={c}/></svg>
        {SF.wifi(c, 14)}
        {/* battery */}
        <svg width="24" height="12" viewBox="0 0 24 12"><rect x="0.5" y="0.5" width="20" height="11" rx="3" fill="none" stroke={c} strokeOpacity="0.45"/><rect x="2" y="2" width="14" height="8" rx="1.5" fill={c}/><rect x="21" y="4" width="2" height="4" rx="1" fill={c} opacity="0.45"/></svg>
      </div>
    </div>
  );
}

function StirDynamicIsland() {
  return <div style={{ position: 'absolute', top: 10, left: '50%', transform: 'translateX(-50%)',
    width: 120, height: 34, borderRadius: 20, background: '#000', zIndex: 100 }} />;
}

function StirTabBar({ active = 'tonight', dark }) {
  const c = useStir(dark);
  const items = [
    { key: 'tonight', label: 'Tonight', icon: SF.fork },
    { key: 'saved',   label: 'Saved',   icon: (col, s) => SF.bookmark(col, s, active === 'saved') },
    { key: 'settings',label: 'Settings',icon: SF.gear },
  ];
  return (
    <div style={{ borderTop: `1px solid ${c.ink100}`, background: c.bg,
      padding: '8px 0 24px', display: 'flex', justifyContent: 'space-around' }}>
      {items.map(it => {
        const on = it.key === active;
        const col = on ? c.ember : c.ink500;
        return (
          <div key={it.key} style={{ display: 'flex', flexDirection: 'column',
            alignItems: 'center', gap: 4, minWidth: 64 }}>
            {it.icon(col, 22)}
            <span style={{ fontFamily: '-apple-system, "SF Pro Text", system-ui',
              fontSize: 11, fontWeight: 500, color: col, letterSpacing: 0.1 }}>{it.label}</span>
          </div>
        );
      })}
    </div>
  );
}

function StirFrame({ children, dark = false, time = '7:42', showTab = false, activeTab = 'tonight',
                     label, width = 390, height = 844 }) {
  const c = useStir(dark);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12 }}>
      {label && <span style={{ fontFamily: '-apple-system, system-ui', fontSize: 12,
        color: '#6B5F54', letterSpacing: 0.3, textTransform: 'uppercase' }}>{label}</span>}
      <div style={{ width: width+12, height: height+12, padding: 6,
        background: dark ? '#0a0805' : '#f7f3ec',
        borderRadius: 54, boxShadow: `0 2px 0 ${dark ? '#2a2520' : '#e8e1d4'} inset, 0 30px 60px rgba(26,22,18,0.18)` }}>
        <div style={{ width, height, borderRadius: 48, background: c.bg, overflow: 'hidden',
          position: 'relative', fontFamily: '-apple-system, "SF Pro Text", system-ui',
          WebkitFontSmoothing: 'antialiased', color: c.ink900 }}>
          <StirDynamicIsland />
          <StirStatusBar dark={dark} time={time} />
          <div style={{ height: height - 44 - (showTab ? 78 : 0), overflow: 'hidden',
            display: 'flex', flexDirection: 'column' }}>{children}</div>
          {showTab && <StirTabBar active={activeTab} dark={dark} />}
          {/* home indicator */}
          <div style={{ position: 'absolute', bottom: 8, left: '50%', transform: 'translateX(-50%)',
            width: 134, height: 5, borderRadius: 999, background: dark ? '#F5F0E8' : '#1A1612', opacity: 0.4 }} />
        </div>
      </div>
    </div>
  );
}

// Page shell — letterboxes and labels two phones side-by-side
function StirKitPage({ title, subtitle, children, bg = '#EFEAE1' }) {
  return (
    <div style={{ minHeight: '100vh', background: bg, padding: '40px 28px 60px',
      fontFamily: '-apple-system, system-ui' }}>
      <header style={{ maxWidth: 1200, margin: '0 auto 32px' }}>
        <div style={{ fontFamily: 'ui-serif, "Source Serif 4", Georgia, serif', fontWeight: 600,
          fontSize: 34, letterSpacing: -0.6, color: '#1A1612' }}>{title}</div>
        {subtitle && <div style={{ fontSize: 14, color: '#6B5F54', marginTop: 4, maxWidth: 680 }}>{subtitle}</div>}
      </header>
      <main style={{ maxWidth: 1200, margin: '0 auto' }}>{children}</main>
    </div>
  );
}

Object.assign(window, { StirFrame, StirStatusBar, StirTabBar, StirDynamicIsland, StirKitPage, SF, STIR_LIGHT, STIR_DARK, useStir });
