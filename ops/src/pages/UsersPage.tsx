import { useEffect, useState } from 'react';
import { callAdmin } from '../lib/api';
import { useConfirm } from '../components/ConfirmDialog';

interface UserRow {
  canonical_user_key: string;
  tier: string;
  billing_state: string;
  status: string;
  last_seen_at: string;
  ai_cost_usd_30d: number;
  flagged_open_count: number;
  reauth_required_at: string | null;
}
interface UsersListResponse {
  total_count: number;
  users: UserRow[];
  limit: number;
  offset: number;
}

export default function UsersPage() {
  const [users, setUsers] = useState<UserRow[]>([]);
  const [total, setTotal] = useState(0);
  const [tier, setTier] = useState<string>('');
  const [search, setSearch] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [actionMsg, setActionMsg] = useState<string | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const { ask, dialog } = useConfirm();

  async function load() {
    setErr(null);
    try {
      const params: Record<string, unknown> = { limit: 100 };
      if (tier) params.tier = tier;
      if (search.trim()) params.search = search.trim();
      const r = await callAdmin<UsersListResponse>('users.list', params);
      setUsers(r.users);
      setTotal(r.total_count);
    } catch (e) {
      setErr(String(e));
    }
  }
  useEffect(() => { load(); /* eslint-disable-next-line */ }, []);

  async function forceReauth(key: string) {
    const result = await ask({
      title: 'Force re-auth',
      description: (
        <>
          <div>Invalidate every JWT and force Sign-in-with-Apple re-flow for:</div>
          <div className="font-mono text-xs mt-2 break-all">{key}</div>
        </>
      ),
      mode: { kind: 'typed', expected: 'REAUTH', placeholder: 'REAUTH' },
      confirmLabel: 'Force re-auth',
    });
    if (!result.confirmed) return;
    setBusyKey(key);
    setActionMsg(null);
    try {
      await callAdmin('users.force_reauth', { canonical_user_key: key });
      await load();
      setActionMsg(`Forced re-auth on ${key}.`);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  async function resetQuota(key: string) {
    const result = await ask({
      title: 'Reset quota',
      description: (
        <>
          <div>Zero the current-period used_count for:</div>
          <div className="font-mono text-xs mt-2 break-all">{key}</div>
        </>
      ),
      mode: {
        kind: 'enum_select',
        options: [
          { value: 'dinner_solve',       label: 'dinner_solve (monthly solve budget)' },
          { value: 'voice_cook_session', label: 'voice_cook_session (monthly voice sessions)' },
          { value: 'recipe_import',      label: 'recipe_import (monthly imports)' },
        ],
      },
      confirmLabel: 'Reset',
    });
    if (!result.confirmed || typeof result.value !== 'string') return;
    setBusyKey(key);
    setActionMsg(null);
    try {
      await callAdmin('users.reset_quota', { canonical_user_key: key, feature_key: result.value });
      setActionMsg(`Quota reset: ${result.value} for ${key}.`);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  async function toggleBan(key: string, currentStatus: string) {
    const newStatus = currentStatus === 'banned' ? 'active' : 'banned';
    const verb = newStatus === 'banned' ? 'Ban' : 'Unban';
    const result = await ask({
      title: `${verb} user`,
      description: (
        <>
          <div>Transition status to <span className="font-mono text-amber-400">{newStatus}</span> for:</div>
          <div className="font-mono text-xs mt-2 break-all">{key}</div>
        </>
      ),
      mode: { kind: 'typed', expected: newStatus === 'banned' ? 'BAN' : 'UNBAN' },
      confirmLabel: verb,
    });
    if (!result.confirmed) return;
    setBusyKey(key);
    setActionMsg(null);
    try {
      await callAdmin('users.status', { canonical_user_key: key, status: newStatus });
      await load();
      setActionMsg(`${verb}ned ${key}.`);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">Users</h1>
      <div className="flex flex-wrap gap-2 mb-4">
        <select value={tier} onChange={(e) => setTier(e.target.value)} className="bg-neutral-800 rounded px-2 py-1 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500">
          <option value="">All tiers</option>
          <option value="free">Free</option>
          <option value="premium">Premium</option>
          <option value="pro">Pro</option>
        </select>
        <input
          placeholder="search canonical_user_key / RC id / install id"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="bg-neutral-800 rounded px-2 py-1 text-sm flex-1 min-w-[12rem] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
        />
        <button onClick={load} className="bg-amber-500 text-neutral-950 rounded px-3 py-1 text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-950">
          Refresh
        </button>
      </div>
      {err && <p className="text-red-400 mb-4 text-sm">{err}</p>}
      {actionMsg && <p className="text-green-400 mb-4 text-sm" role="status">{actionMsg}</p>}
      <div className="text-xs text-neutral-400 mb-2">{total.toLocaleString()} total</div>
      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead className="text-neutral-400 text-xs uppercase border-b border-neutral-800">
            <tr>
              <th className="text-left p-2">canonical_user_key</th>
              <th className="text-left p-2">tier</th>
              <th className="text-left p-2 hidden md:table-cell">billing</th>
              <th className="text-left p-2">status</th>
              <th className="text-right p-2 hidden md:table-cell">$30d</th>
              <th className="text-right p-2">flags</th>
              <th className="text-left p-2 hidden md:table-cell">last seen</th>
              <th className="text-left p-2">actions</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.canonical_user_key} className="border-b border-neutral-900 hover:bg-neutral-900/50">
                <td className="p-2 font-mono text-xs">{u.canonical_user_key}</td>
                <td className="p-2">{u.tier}</td>
                <td className="p-2 hidden md:table-cell">{u.billing_state}</td>
                <td className="p-2">
                  <span className={u.status === 'banned' ? 'text-red-400' : ''}>{u.status}</span>
                </td>
                <td className="p-2 text-right hidden md:table-cell">${Number(u.ai_cost_usd_30d).toFixed(2)}</td>
                <td className="p-2 text-right">{u.flagged_open_count}</td>
                <td className="p-2 text-neutral-400 hidden md:table-cell">{new Date(u.last_seen_at).toLocaleDateString()}</td>
                <td className="p-2 space-x-1 whitespace-nowrap">
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => forceReauth(u.canonical_user_key)}
                    className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-950"
                  >
                    reauth
                  </button>
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => resetQuota(u.canonical_user_key)}
                    className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-950"
                  >
                    reset quota
                  </button>
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => toggleBan(u.canonical_user_key, u.status)}
                    className="text-xs text-red-400 border border-red-900/60 hover:bg-red-900 hover:text-white rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-950"
                  >
                    {u.status === 'banned' ? 'unban' : 'ban'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {dialog}
    </div>
  );
}
