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
  async function signOut() {
    await supabase.auth.signOut();
    nav('/');
  }
  return (
    <div className="min-h-screen flex">
      <nav className="w-56 bg-neutral-900 border-r border-neutral-800 flex flex-col p-4">
        <h1 className="font-semibold mb-6">Stir Ops</h1>
        <ul className="flex flex-col gap-1 text-sm">
          {NAV_ITEMS.map((item) => (
            <li key={item.to}>
              <NavLink
                to={item.to}
                end
                className={({ isActive }) =>
                  `block px-3 py-2 rounded hover:bg-neutral-800 ${isActive ? 'bg-neutral-800 text-amber-300' : 'text-neutral-300'}`
                }
              >
                {item.label}
              </NavLink>
            </li>
          ))}
        </ul>
        <div className="mt-auto pt-6 border-t border-neutral-800 text-xs text-neutral-500">
          <div className="mb-2 truncate">{session.user.email}</div>
          <button className="text-neutral-300 hover:text-amber-300" onClick={signOut}>Sign out</button>
        </div>
      </nav>
      <main className="flex-1 p-8 overflow-auto">
        <Outlet />
      </main>
    </div>
  );
}
