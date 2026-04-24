import { useEffect, useState } from 'react';
import { callAdmin } from '../lib/api';

interface UsersListResponse {
  total_count: number;
  users: unknown[];
}
interface FlaggedListResponse {
  total_count: number;
}
interface AnomaliesResponse {
  total_count: number;
}

export default function DashboardPage() {
  const [totalUsers, setTotalUsers] = useState<number | null>(null);
  const [openFlags, setOpenFlags] = useState<number | null>(null);
  const [openAnomalies, setOpenAnomalies] = useState<number | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([
      callAdmin<UsersListResponse>('users.list', { limit: 1 }),
      callAdmin<FlaggedListResponse>('flagged_outputs.list', { state: 'open', limit: 1 }),
      callAdmin<AnomaliesResponse>('cost_anomalies.list', { resolved: false, limit: 1 }),
    ])
      .then(([u, f, a]) => {
        setTotalUsers(u.total_count);
        setOpenFlags(f.total_count);
        setOpenAnomalies(a.total_count);
      })
      .catch((e) => setErr(String(e)));
  }, []);

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-6">Dashboard</h1>
      {err && <p className="text-red-400 mb-4 text-sm">{err}</p>}
      <div className="grid grid-cols-3 gap-4">
        <KpiCard label="Active users" value={totalUsers} />
        <KpiCard label="Open flagged outputs" value={openFlags} severity={openFlags && openFlags > 0 ? 'warn' : 'normal'} />
        <KpiCard label="Open cost anomalies" value={openAnomalies} severity={openAnomalies && openAnomalies > 0 ? 'warn' : 'normal'} />
      </div>
      <p className="text-xs text-neutral-500 mt-8">
        Detail pages: Users (list + force_reauth / reset quota), Flagged Outputs (resolve dismissed/withdrawn/canned_fallback_pinned),
        Cost Anomalies (severity filter), Voice Sessions (runaway detector), Feature Flags (kill switches), Prompt Versions (rollout %),
        Audit Log (every admin mutation).
      </p>
    </div>
  );
}

function KpiCard(
  { label, value, severity = 'normal' }: { label: string; value: number | null; severity?: 'normal' | 'warn' },
) {
  const tone = severity === 'warn'
    ? 'border-amber-500/40 bg-amber-950/30'
    : 'border-neutral-800 bg-neutral-900';
  return (
    <div className={`rounded-xl border p-6 ${tone}`}>
      <div className="text-sm text-neutral-400">{label}</div>
      <div className="text-3xl font-semibold mt-2">{value === null ? '…' : value.toLocaleString()}</div>
    </div>
  );
}
