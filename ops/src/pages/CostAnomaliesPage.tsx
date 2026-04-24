import { useEffect, useState } from 'react';
import { callAdmin } from '../lib/api';

interface AnomalyRow {
  id: string;
  canonical_user_key_hash: string;
  anomaly_type: string;
  severity: 'warn' | 'critical';
  details_json: Record<string, unknown>;
  detected_at: string;
  alerted_at: string | null;
  resolved_at: string | null;
}

export default function CostAnomaliesPage() {
  const [rows, setRows] = useState<AnomalyRow[]>([]);
  const [severity, setSeverity] = useState<string>('');
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const params: Record<string, unknown> = { limit: 100, resolved: false };
    if (severity) params.severity = severity;
    setLoading(true);
    setErr(null);
    callAdmin<{ rows: AnomalyRow[] }>('cost_anomalies.list', params)
      .then((r) => setRows(r.rows))
      .catch((e) => setErr(String(e)))
      .finally(() => setLoading(false));
  }, [severity]);

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">Cost Anomalies</h1>
      <div className="flex flex-wrap gap-2 mb-4 text-sm">
        <button onClick={() => setSeverity('')} className={`px-3 py-1 rounded ${!severity ? 'bg-amber-500 text-neutral-950' : 'bg-neutral-800'}`}>All</button>
        <button onClick={() => setSeverity('warn')} className={`px-3 py-1 rounded ${severity === 'warn' ? 'bg-amber-500 text-neutral-950' : 'bg-neutral-800'}`}>Warn</button>
        <button onClick={() => setSeverity('critical')} className={`px-3 py-1 rounded ${severity === 'critical' ? 'bg-red-500 text-white' : 'bg-neutral-800'}`}>Critical</button>
      </div>
      {err && <p className="text-red-400 text-sm mb-4" role="alert">{err}</p>}
      <section aria-label={`${severity || 'all'} open cost anomalies`} className="space-y-2">
        {loading && <p className="text-neutral-400 text-sm">Loading…</p>}
        {!loading && rows.map((r) => (
          <article
            key={r.id}
            aria-label={`${r.severity} ${r.anomaly_type}`}
            className={`rounded p-3 ${r.severity === 'critical' ? 'bg-red-950/40 border border-red-900' : 'bg-amber-950/30 border border-amber-900'}`}
          >
            <div className="flex justify-between text-xs">
              <span className="font-mono">{r.canonical_user_key_hash}</span>
              <span className="text-neutral-400">{new Date(r.detected_at).toLocaleString()}</span>
            </div>
            <div className="mt-1 text-sm font-medium">{r.anomaly_type} · {r.severity}</div>
            <pre className="text-xs text-neutral-300 mt-2">{JSON.stringify(r.details_json, null, 2)}</pre>
            <div className="text-xs text-neutral-400 mt-2">
              {r.alerted_at ? `alerted ${new Date(r.alerted_at).toLocaleString()}` : 'alert pending'}
            </div>
          </article>
        ))}
        {/* S20 (DB1 #20): gate empty-state on !err so a failed fetch
            doesn't show "No open anomalies" when the fetch actually errored. */}
        {!loading && !err && rows.length === 0 && (
          <p className="text-neutral-400 text-sm">No open anomalies in this filter.</p>
        )}
      </section>
    </div>
  );
}
