// SCA-82 — TanStack Query migration of DashboardPage. The 3 KPI cards
// each get their own useQuery so a single endpoint failure shows as a
// per-card error without blanking the whole dashboard (matching the
// prior W42 Promise.allSettled invariant).

import { useQuery } from '@tanstack/react-query';
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

// Tiered severity (review W29).
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
  const usersQ = useQuery({
    queryKey: ['dashboard', 'users'],
    queryFn: () => callAdmin<UsersListResponse>('users.list', { limit: 1 }),
  });
  const flagsQ = useQuery({
    queryKey: ['dashboard', 'flags'],
    queryFn: () => callAdmin<FlaggedListResponse>('flagged_outputs.list', { state: 'open', limit: 1 }),
  });
  const anomaliesQ = useQuery({
    queryKey: ['dashboard', 'anomalies'],
    queryFn: () => callAdmin<AnomaliesResponse>('cost_anomalies.list', { resolved: false, limit: 1 }),
  });

  const usersCard = toCardState(usersQ);
  const flagsCard = toCardState(flagsQ);
  const anomaliesCard = toCardState(anomaliesQ);

  const flagValue = flagsCard.status === 'loaded' ? flagsCard.value : null;
  const anomalyValue = anomaliesCard.status === 'loaded' ? anomaliesCard.value : null;

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-6">Dashboard</h1>
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <KpiCard label="Active users" state={usersCard} />
        <KpiCard
          label="Open flagged outputs"
          state={flagsCard}
          severity={severityFor(flagValue, FLAG_WARN_THRESHOLD, FLAG_CRITICAL_THRESHOLD)}
        />
        <KpiCard
          label="Open cost anomalies"
          state={anomaliesCard}
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

function toCardState<T extends { total_count: number }>(
  q: { isLoading: boolean; data: T | undefined; error: unknown },
): CardState {
  if (q.isLoading) return { status: 'loading' };
  if (q.error) return { status: 'error', message: String(q.error) };
  if (q.data) return { status: 'loaded', value: q.data.total_count };
  return { status: 'loading' };
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
