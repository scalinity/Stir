import { useState } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import type { Session } from '@supabase/supabase-js';

const NAV_ITEMS = [
  { to: '/', label: 'Dashboard' },
  { to: '/users', label: 'Users' },
  { to: '/flagged', label: 'Flagged Outputs' },
  { to: '/anomalies', label: 'Cost Anomalies' },
  { to: '/voice', label: 'Voice Sessions' },
  { to: '/flags', label: 'Feature Flags' },
  { to: '/prompts', label: 'Prompt Versions' },
  { to: '/audit', label: 'Audit Log' },
];

export default function AppShell({ session }: { session: Session }) {
  const nav = useNavigate();
  const [menuOpen, setMenuOpen] = useState(false);

  async function signOut() {
    await supabase.auth.signOut();
    nav('/');
  }

  return (
    <div className="min-h-screen md:flex">
      {/* Mobile top bar with hamburger toggle — only visible < md. */}
      <div className="md:hidden flex items-center justify-between bg-neutral-900 border-b border-neutral-800 px-4 py-3 sticky top-0 z-20">
        <h1 className="font-semibold">Stir Ops</h1>
        <button
          aria-expanded={menuOpen}
          aria-controls="ops-nav"
          onClick={() => setMenuOpen((v) => !v)}
          className="text-neutral-300 hover:text-amber-300"
        >
          {menuOpen ? 'Close' : 'Menu'}
        </button>
      </div>

      <nav
        id="ops-nav"
        className={`md:w-56 bg-neutral-900 border-r border-neutral-800 flex-col p-4 md:flex ${menuOpen ? 'flex' : 'hidden'} md:min-h-screen`}
      >
        <h1 className="font-semibold mb-6 hidden md:block">Stir Ops</h1>
        <ul className="flex flex-col gap-1 text-sm">
          {NAV_ITEMS.map((item) => (
            <li key={item.to}>
              <NavLink
                to={item.to}
                end
                onClick={() => setMenuOpen(false)}
                className={({ isActive }) =>
                  `block px-3 py-2 rounded hover:bg-neutral-800 ${isActive ? 'bg-neutral-800 text-amber-300' : 'text-neutral-300'}`
                }
              >
                {item.label}
              </NavLink>
            </li>
          ))}
        </ul>
        <div className="mt-auto pt-6 border-t border-neutral-800 text-xs text-neutral-400">
          <div className="mb-2 truncate">{session.user.email}</div>
          <button className="text-neutral-300 hover:text-amber-300" onClick={signOut}>Sign out</button>
        </div>
      </nav>

      <main className="flex-1 p-4 md:p-8 overflow-auto">
        <Outlet />
      </main>
    </div>
  );
}
