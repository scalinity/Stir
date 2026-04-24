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

type CardState =
  | { status: 'loading' }
  | { status: 'loaded'; value: number }
  | { status: 'error'; message: string };

// Tiered severity (review W29): a backlog of 3 pending flags shouldn't
// scream the same as 50 critical anomalies.
const FLAG_WARN_THRESHOLD = 5;
const FLAG_CRITICAL_THRESHOLD = 25;
const ANOMALY_WARN_THRESHOLD = 1;
const ANOMALY_CRITICAL_THRESHOLD = 10;

function severityFor(value: number | null, warn: number, critical: number): Severity {
  if (value === null || value <= 0) return 'normal';
  if (value >= critical) return 'critical';
  if (value >= warn) return 'warn';
  return 'normal';
}

type Severity = 'normal' | 'warn' | 'critical';

export default function DashboardPage() {
  const [users, setUsers] = useState<CardState>({ status: 'loading' });
  const [flags, setFlags] = useState<CardState>({ status: 'loading' });
  const [anomalies, setAnomalies] = useState<CardState>({ status: 'loading' });

  useEffect(() => {
    // W42 (DB1 #14): Promise.allSettled so a single endpoint failure doesn't
    // blank the whole dashboard during the exact moment an admin needs it.
    Promise.allSettled([
      callAdmin<UsersListResponse>('users.list', { limit: 1 }),
      callAdmin<FlaggedListResponse>('flagged_outputs.list', { state: 'open', limit: 1 }),
      callAdmin<AnomaliesResponse>('cost_anomalies.list', { resolved: false, limit: 1 }),
    ]).then(([u, f, a]) => {
      setUsers(u.status === 'fulfilled'
        ? { status: 'loaded', value: u.value.total_count }
        : { status: 'error', message: String(u.reason) });
      setFlags(f.status === 'fulfilled'
        ? { status: 'loaded', value: f.value.total_count }
        : { status: 'error', message: String(f.reason) });
      setAnomalies(a.status === 'fulfilled'
        ? { status: 'loaded', value: a.value.total_count }
        : { status: 'error', message: String(a.reason) });
    });
  }, []);

  const flagValue = flags.status === 'loaded' ? flags.value : null;
  const anomalyValue = anomalies.status === 'loaded' ? anomalies.value : null;

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-6">Dashboard</h1>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <KpiCard label="Active users" state={users} />
        <KpiCard
          label="Open flagged outputs"
          state={flags}
          severity={severityFor(flagValue, FLAG_WARN_THRESHOLD, FLAG_CRITICAL_THRESHOLD)}
        />
        <KpiCard
          label="Open cost anomalies"
          state={anomalies}
          severity={severityFor(anomalyValue, ANOMALY_WARN_THRESHOLD, ANOMALY_CRITICAL_THRESHOLD)}
        />
      </div>
      <p className="text-xs text-neutral-400 mt-8">
        Detail pages: Users (list + force_reauth / reset quota), Flagged Outputs (resolve dismissed/withdrawn/canned_fallback_pinned),
        Cost Anomalies (severity filter), Voice Sessions (runaway detector), Feature Flags (kill switches), Prompt Versions (rollout %),
        Audit Log (every admin mutation).
      </p>
    </div>
  );
}

function KpiCard(
  { label, state, severity = 'normal' }: { label: string; state: CardState; severity?: Severity },
) {
  const tone =
    severity === 'critical' ? 'border-red-500/50 bg-red-950/30' :
    severity === 'warn'     ? 'border-amber-500/40 bg-amber-950/30' :
                              'border-neutral-800 bg-neutral-900';

  return (
    <div className={`rounded-xl border p-6 ${tone}`}>
      <div className="text-sm text-neutral-400">{label}</div>
      {state.status === 'loading' && (
        <div className="text-3xl font-semibold mt-2 text-neutral-500">…</div>
      )}
      {state.status === 'loaded' && (
        <div className="text-3xl font-semibold mt-2">{state.value.toLocaleString()}</div>
      )}
      {state.status === 'error' && (
        <div className="mt-2 text-sm text-red-400" role="alert">
          failed: {state.message.slice(0, 40)}{state.message.length > 40 ? '…' : ''}
        </div>
      )}
    </div>
  );
}
