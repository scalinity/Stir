// SCA-82 — TanStack Query migration of FlaggedOutputsPage.

import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { callAdmin } from '../lib/api';
import { useConfirm } from '../components/ConfirmDialog';

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
  const [state, setState] = useState<'open' | 'resolved' | 'all'>('open');
  const [actionMsg, setActionMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const { ask, dialog } = useConfirm();
  const queryClient = useQueryClient();

  const { data, isLoading, error } = useQuery({
    queryKey: ['flagged_outputs', { state }],
    queryFn: () =>
      callAdmin<{ rows: FlaggedRow[]; total_count: number }>('flagged_outputs.list', {
        state,
        limit: 100,
      }),
  });
  const rows = data?.rows ?? [];

  const resolveMutation = useMutation({
    mutationFn: (params: Record<string, unknown>) =>
      callAdmin('flagged_outputs.resolve', params),
    onSuccess: (_data: unknown, vars: Record<string, unknown>) => {
      queryClient.invalidateQueries({ queryKey: ['flagged_outputs'] });
      setActionMsg(`Resolved (${String(vars.action ?? 'unknown')}).`);
    },
  });

  const err = error ? String(error) : (resolveMutation.error ? String(resolveMutation.error) : null);

  async function resolve(id: string, action: 'dismissed' | 'withdrawn' | 'canned_fallback_pinned') {
    const params: Record<string, unknown> = { id, action };

    if (action === 'canned_fallback_pinned') {
      const jsonResult = await ask({
        title: 'Pin canned fallback',
        description: 'Replace the cached response body for this request with a safe fallback. The body is decoded by iOS on the next cache hit, so make sure the shape matches the feature.',
        mode: { kind: 'json', placeholder: '{"key":"value"}' },
        confirmLabel: 'Pin fallback',
      });
      if (!jsonResult.confirmed) return;
      params.canned_fallback_json = jsonResult.value;
    } else if (action === 'withdrawn') {
      const confirmResult = await ask({
        title: 'Withdraw output',
        description: 'Deletes the cached response so the next retry hits fresh generation. No fallback is pinned.',
        mode: { kind: 'plain' },
        confirmLabel: 'Withdraw',
      });
      if (!confirmResult.confirmed) return;
    } else {
      const confirmResult = await ask({
        title: 'Dismiss flag',
        description: 'Mark this flag as reviewed, no cache mutation.',
        mode: { kind: 'plain', destructive: false },
        confirmLabel: 'Dismiss',
      });
      if (!confirmResult.confirmed) return;
    }

    setBusy(id);
    setActionMsg(null);
    try {
      await resolveMutation.mutateAsync(params);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">Flagged Outputs</h1>
      <div
        className="flex flex-wrap gap-2 mb-4"
        role="group"
        aria-label="Filter flagged outputs by state"
      >
        {(['open', 'resolved', 'all'] as const).map((s) => (
          <button
            key={s}
            onClick={() => setState(s)}
            aria-pressed={state === s}
            className={`text-sm px-3 py-1 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-950 ${
              state === s
                ? s === 'open' ? 'bg-amber-500 text-neutral-950 focus-visible:ring-amber-500' : 'bg-neutral-600 focus-visible:ring-neutral-500'
                : 'bg-neutral-800 focus-visible:ring-amber-500'
            }`}
          >
            {s}
          </button>
        ))}
      </div>
      {err && <p className="text-red-400 text-sm mb-4">{err}</p>}
      {actionMsg && <p className="text-green-400 text-sm mb-4" role="status">{actionMsg}</p>}
      <section aria-label={`${state} flagged outputs`} className="space-y-3">
        {isLoading && <p className="text-neutral-400 text-sm">Loading…</p>}
        {!isLoading && rows.map((r: FlaggedRow) => (
          <article
            key={r.id}
            aria-label={`${r.feature_key} flag by ${r.flagged_by}: ${r.flag_reason.slice(0, 80)}`}
            className="border border-neutral-800 rounded p-4 bg-neutral-900"
          >
            <div className="flex justify-between text-xs text-neutral-400 mb-2">
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
              <div className="text-xs text-neutral-400">Resolved {r.resolution_action} · {new Date(r.resolved_at).toLocaleString()}</div>
            ) : (
              <div className="flex flex-wrap gap-2">
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'dismissed')}
                  className="text-xs bg-neutral-800 hover:bg-neutral-700 rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-900">dismiss</button>
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'withdrawn')}
                  className="text-xs bg-red-900 hover:bg-red-800 text-white rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-900">withdraw (delete cache)</button>
                <button disabled={busy === r.id} onClick={() => resolve(r.id, 'canned_fallback_pinned')}
                  className="text-xs bg-amber-800 hover:bg-amber-700 rounded px-2 py-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-1 focus-visible:ring-offset-neutral-900">pin fallback</button>
              </div>
            )}
          </article>
        ))}
        {!isLoading && rows.length === 0 && !err && <p className="text-neutral-400 text-sm">No flagged outputs in this state.</p>}
      </section>
      {dialog}
    </div>
  );
}
