// SCA-61 — ops admin tab for CCPA / privacy-rights deletion queue.
//
// Lists deletion_requests with state filter; surfaces an "Approve" CTA
// on pending rows that flips state to approved (the downstream pgmq
// fulfillment worker is tracked under SCA-88).
//
// Pattern matches CostAnomaliesPage / FlaggedOutputsPage: useQuery
// keyed on filter, useMutation w/ onSuccess invalidation. No
// useEffect (CLAUDE.md global rule).

import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { callAdmin } from '../lib/api';
import { useConfirm } from '../components/ConfirmDialog';

interface DeletionRow {
  id: string;
  canonical_user_key_hash: string;
  state: 'pending' | 'approved' | 'processing' | 'completed' | 'failed';
  requested_at: string;
  approved_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  failure_reason: string | null;
}

type StateFilter = '' | 'pending' | 'approved' | 'processing' | 'failed';

export default function DeletionRequestsPage() {
  const [stateFilter, setStateFilter] = useState<StateFilter>('pending');
  const queryClient = useQueryClient();
  const { ask, dialog } = useConfirm();

  const { data, isLoading, error } = useQuery({
    queryKey: ['deletion_requests', { state: stateFilter }],
    queryFn: async () => {
      const params: Record<string, unknown> = { limit: 100 };
      if (stateFilter) params.state = stateFilter;
      return callAdmin<{ rows: DeletionRow[]; total_count: number }>(
        'deletion_requests.list',
        params,
      );
    },
  });

  const approveMutation = useMutation({
    mutationFn: async (id: string) =>
      await callAdmin<{ ok: true }>('deletion_requests.approve', { id }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['deletion_requests'] });
    },
  });

  const rows = data?.rows ?? [];
  const err = error ? String(error) : null;

  const onApprove = async (row: DeletionRow) => {
    const confirmed = await ask({
      title: 'Approve deletion request?',
      description: (
        <>
          User hash: <code>{row.canonical_user_key_hash}</code>
          <br />
          <br />
          Approval marks the row for fulfillment by the downstream pgmq worker. The user's data will
          be erased across all subsystems within 30 days. This action is logged in audit_log.
        </>
      ),
      confirmLabel: 'Approve',
      mode: { kind: 'plain', destructive: true },
    });
    if (!confirmed.confirmed) return;
    approveMutation.mutate(row.id);
  };

  return (
    <div>
      {dialog}
      <h1 className="text-2xl font-semibold mb-4">Deletion Requests</h1>

      <div
        className="flex flex-wrap gap-2 mb-4 text-sm"
        role="group"
        aria-label="Filter deletion requests by state"
      >
        {(['pending', 'approved', 'processing', 'failed', ''] as StateFilter[]).map((s) => (
          <button
            key={s || 'all'}
            onClick={() => setStateFilter(s)}
            aria-pressed={stateFilter === s}
            className={`px-3 py-1 rounded ${
              stateFilter === s ? 'bg-amber-500 text-neutral-950' : 'bg-neutral-800'
            }`}
          >
            {s || 'all in-flight'}
          </button>
        ))}
      </div>

      {err && (
        <p className="text-red-400 text-sm mb-4" role="alert">
          {err}
        </p>
      )}

      {approveMutation.isError && (
        <p className="text-red-400 text-sm mb-4" role="alert">
          Approve failed: {String(approveMutation.error)}
        </p>
      )}

      <section aria-label="deletion requests" className="space-y-2">
        {isLoading && <p className="text-neutral-400 text-sm">Loading…</p>}
        {!isLoading && rows.map((r: DeletionRow) => (
          <article
            key={r.id}
            aria-label={`${r.state} deletion request`}
            className="rounded p-3 bg-neutral-900 border border-neutral-800"
          >
            <div className="flex justify-between text-xs">
              <span className="font-mono">{r.canonical_user_key_hash}</span>
              <span className="text-neutral-400">
                requested {new Date(r.requested_at).toLocaleString()}
              </span>
            </div>
            <div className="mt-1 text-sm font-medium">
              <span className={stateBadgeClass(r.state)}>{r.state}</span>
            </div>
            {r.approved_at && (
              <div className="text-xs text-neutral-400 mt-1">
                approved {new Date(r.approved_at).toLocaleString()}
              </div>
            )}
            {r.completed_at && (
              <div className="text-xs text-neutral-400 mt-1">
                completed {new Date(r.completed_at).toLocaleString()}
              </div>
            )}
            {r.failure_reason && (
              <div className="text-xs text-red-300 mt-1 whitespace-pre-wrap">
                failure: {r.failure_reason}
              </div>
            )}
            {r.state === 'pending' && (
              <div className="mt-3">
                <button
                  type="button"
                  onClick={() => onApprove(r)}
                  disabled={approveMutation.isPending}
                  className="px-3 py-1 rounded bg-red-700 text-white text-xs disabled:opacity-60"
                >
                  Approve deletion
                </button>
              </div>
            )}
          </article>
        ))}
        {!isLoading && !err && rows.length === 0 && (
          <p className="text-neutral-400 text-sm">No deletion requests in this filter.</p>
        )}
      </section>
    </div>
  );
}

function stateBadgeClass(state: DeletionRow['state']): string {
  switch (state) {
    case 'pending':
      return 'inline-block px-2 py-0.5 rounded bg-amber-900 text-amber-100 text-xs';
    case 'approved':
      return 'inline-block px-2 py-0.5 rounded bg-blue-900 text-blue-100 text-xs';
    case 'processing':
      return 'inline-block px-2 py-0.5 rounded bg-indigo-900 text-indigo-100 text-xs';
    case 'completed':
      return 'inline-block px-2 py-0.5 rounded bg-emerald-900 text-emerald-100 text-xs';
    case 'failed':
      return 'inline-block px-2 py-0.5 rounded bg-red-900 text-red-100 text-xs';
  }
}
