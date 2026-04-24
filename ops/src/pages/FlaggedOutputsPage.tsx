import { useEffect, useState } from 'react';
import { callAdmin } from '../lib/api';

interface FlaggedRow {
  id: string;
  feature_key: string;
  flagged_by: string;
  flag_reason: string;
  created_at: string;
  resolved_at: string | null;
  resolution_action: string | null;
  raw_output_json: unknown;
}

export default function FlaggedOutputsPage() {
  const [rows, setRows] = useState<FlaggedRow[]>([]);
  const [state, setState] = useState<'open' | 'resolved' | 'all'>('open');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  async function load() {
    setErr(null);
    try {
      const r = await callAdmin<{ rows: FlaggedRow[]; total_count: number }>(
        'flagged_outputs.list',
        { state, limit: 100 },
      );
      setRows(r.rows);
    } catch (e) {
      setErr(String(e));
    }
  }
  useEffect(() => { load(); /* eslint-disable-next-line */ }, [state]);

  async function resolve(id: string, action: 'dismissed' | 'withdrawn' | 'canned_fallback_pinned') {
    const params: Record<string, unknown> = { id, action };
    if (action === 'canned_fallback_pinned') {
      const raw = prompt('canned_fallback_json (JSON body that will replace cache):');
      if (!raw) return;
      try { params.canned_fallback_json = JSON.parse(raw); }
      catch { alert('invalid JSON'); return; }
    }
    const note = prompt('resolution note (optional):') ?? undefined;
    if (note) params.resolution_notes = note;
    setBusy(id);
    try {
      await callAdmin('flagged_outputs.resolve', params);
      await load();
    } catch (e) {
      alert(String(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">Flagged Outputs</h1>
      <div className="flex gap-2 mb-4">
        {(['open', 'resolved', 'all'] as const).map((s) => (
          <button
            key={s}
            onClick={() => setState(s)}
            className={`text-sm px-3 py-1 rounded ${state === s ? 'bg-amber-500 text-neutral-950' : 'bg-neutral-800'}`}
          >
            {s}
          </button>
        ))}
      </div>
      {err && <p className="text-red-400 text-sm mb-4">{err}</p>}
      <div className="space-y-3">
        {rows.map((r) => (
          <div key={r.id} className="border border-neutral-800 rounded p-4 bg-neutral-900">
            <div className="flex justify-between text-xs text-neutral-500 mb-2">
              <span>{r.feature_key} · {r.flagged_by}</span>
              <span>{new Date(r.created_at).toLocaleString()}</span>
            </div>
            <div className="text-sm mb-2">{r.flag_reason}</div>
            {r.raw_output_json != null && (
              <details className="text-xs text-neutral-400 mb-2">
                <summary className="cursor-pointer">raw output</summary>
                <pre className="mt-2 bg-neutral-950 p-2 rounded overflow-auto max-h-64">
                  {JSON.stringify(r.raw_output_json, null, 2)}
                </pre>
              </details>
            )}
            {r.resolved_at ? (
              <div className="text-xs text-neutral-500">Resolved {r.resolution_action} · {new Date(r.resolved_at).toLocaleString()}</div>
            ) : (
              <div className="flex gap-2">
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'dismissed')}
                  className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1">dismiss</button>
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'withdrawn')}
                  className="text-xs bg-red-900 hover:bg-red-800 rounded px-2 py-1">withdraw (delete cache)</button>
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'canned_fallback_pinned')}
                  className="text-xs bg-amber-800 hover:bg-amber-700 rounded px-2 py-1">pin fallback</button>
              </div>
            )}
          </div>
        ))}
        {rows.length === 0 && <p className="text-neutral-500 text-sm">No flagged outputs in this state.</p>}
      </div>
    </div>
  );
}
