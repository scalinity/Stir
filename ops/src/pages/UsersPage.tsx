import { useEffect, useState } from 'react';
import { callAdmin } from '../lib/api';

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
  const [busyKey, setBusyKey] = useState<string | null>(null);

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
    if (!confirm(`Force re-auth for ${key}? Existing session is invalidated.`)) return;
    setBusyKey(key);
    try {
      await callAdmin('users.force_reauth', { canonical_user_key: key });
      await load();
    } catch (e) {
      alert(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  async function resetQuota(key: string) {
    const feature = prompt('feature_key? (dinner_solve | voice_cook_session | recipe_import)');
    if (!feature) return;
    setBusyKey(key);
    try {
      await callAdmin('users.reset_quota', { canonical_user_key: key, feature_key: feature });
      alert('Quota reset.');
    } catch (e) {
      alert(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  async function toggleBan(key: string, currentStatus: string) {
    const newStatus = currentStatus === 'banned' ? 'active' : 'banned';
    if (!confirm(`Set status to ${newStatus} for ${key}?`)) return;
    setBusyKey(key);
    try {
      await callAdmin('users.status', { canonical_user_key: key, status: newStatus });
      await load();
    } catch (e) {
      alert(String(e));
    } finally {
      setBusyKey(null);
    }
  }

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">Users</h1>
      <div className="flex gap-2 mb-4">
        <select value={tier} onChange={(e) => setTier(e.target.value)} className="bg-neutral-800 rounded px-2 py-1 text-sm">
          <option value="">All tiers</option>
          <option value="free">Free</option>
          <option value="premium">Premium</option>
          <option value="pro">Pro</option>
        </select>
        <input
          placeholder="search canonical_user_key / RC id / install id"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="bg-neutral-800 rounded px-2 py-1 text-sm flex-1"
        />
        <button onClick={load} className="bg-amber-500 text-neutral-950 rounded px-3 py-1 text-sm font-medium">
          Refresh
        </button>
      </div>
      {err && <p className="text-red-400 mb-4 text-sm">{err}</p>}
      <div className="text-xs text-neutral-500 mb-2">{total.toLocaleString()} total</div>
      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead className="text-neutral-400 text-xs uppercase border-b border-neutral-800">
            <tr>
              <th className="text-left p-2">canonical_user_key</th>
              <th className="text-left p-2">tier</th>
              <th className="text-left p-2">billing</th>
              <th className="text-left p-2">status</th>
              <th className="text-right p-2">$30d</th>
              <th className="text-right p-2">flags</th>
              <th className="text-left p-2">last seen</th>
              <th className="text-left p-2">actions</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.canonical_user_key} className="border-b border-neutral-900 hover:bg-neutral-900/50">
                <td className="p-2 font-mono text-xs">{u.canonical_user_key}</td>
                <td className="p-2">{u.tier}</td>
                <td className="p-2">{u.billing_state}</td>
                <td className="p-2">
                  <span className={u.status === 'banned' ? 'text-red-400' : ''}>{u.status}</span>
                </td>
                <td className="p-2 text-right">${Number(u.ai_cost_usd_30d).toFixed(2)}</td>
                <td className="p-2 text-right">{u.flagged_open_count}</td>
                <td className="p-2 text-neutral-400">{new Date(u.last_seen_at).toLocaleDateString()}</td>
                <td className="p-2 space-x-1">
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => forceReauth(u.canonical_user_key)}
                    className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1"
                  >
                    reauth
                  </button>
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => resetQuota(u.canonical_user_key)}
                    className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1"
                  >
                    reset quota
                  </button>
                  <button
                    disabled={busyKey === u.canonical_user_key}
                    onClick={() => toggleBan(u.canonical_user_key, u.status)}
                    className="text-xs bg-neutral-800 hover:bg-red-900 rounded px-2 py-1"
                  >
                    {u.status === 'banned' ? 'unban' : 'ban'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
