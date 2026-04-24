// Stir ops — shared confirmation primitive.
//
// Replaces native window.confirm for destructive admin actions. Native
// dialogs can't show context, can't be keyboard-trap-tested, and render
// plain-chrome chrome that looks nothing like the ops UI — a mis-click
// from a 100-row table has real consequences.
//
// Three presentation modes:
//   plain       — one-line prompt + Confirm/Cancel (defaults to destructive style)
//   typed       — require operator to type a specific phrase ("BAN user xyz")
//                 before Confirm activates; primarily for ban/reauth
//   enum_select — a <select> with enumerated options; used by reset_quota
//                 (replaces free-text prompt() with typed values)
//   json        — textarea with JSON.parse badge; used by canned_fallback_pinned
//
// Controlled via a hook: `useConfirm()` returns { ask, dialog }. Mount
// `dialog` once in AppShell; call `await ask({ ... })` from any handler.

import { useCallback, useState } from 'react';
import type { ReactNode } from 'react';

type ConfirmMode =
  | { kind: 'plain'; destructive?: boolean }
  | { kind: 'typed'; expected: string; placeholder?: string }
  | { kind: 'enum_select'; options: Array<{ value: string; label: string }> }
  | { kind: 'json'; placeholder?: string };

export interface ConfirmRequest {
  title: string;
  description?: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  mode: ConfirmMode;
}

export type ConfirmResult =
  | { confirmed: true; value?: string | Record<string, unknown> }
  | { confirmed: false };

interface PendingConfirm extends ConfirmRequest {
  resolve: (r: ConfirmResult) => void;
}

export function useConfirm(): {
  ask: (req: ConfirmRequest) => Promise<ConfirmResult>;
  dialog: ReactNode;
} {
  const [pending, setPending] = useState<PendingConfirm | null>(null);
  const [input, setInput] = useState('');
  const [selectValue, setSelectValue] = useState('');
  const [jsonText, setJsonText] = useState('');
  const [jsonError, setJsonError] = useState<string | null>(null);

  const ask = useCallback((req: ConfirmRequest): Promise<ConfirmResult> => {
    setInput('');
    setSelectValue(req.mode.kind === 'enum_select' ? req.mode.options[0]?.value ?? '' : '');
    setJsonText('');
    setJsonError(null);
    return new Promise<ConfirmResult>((resolve) => {
      setPending({ ...req, resolve });
    });
  }, []);

  const close = useCallback((result: ConfirmResult) => {
    pending?.resolve(result);
    setPending(null);
    setInput('');
    setSelectValue('');
    setJsonText('');
    setJsonError(null);
  }, [pending]);

  const dialog = pending ? (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      onKeyDown={(e) => { if (e.key === 'Escape') close({ confirmed: false }); }}
    >
      <div className="bg-neutral-900 border border-neutral-700 rounded-lg max-w-md w-full p-6 space-y-4">
        <h2 id="confirm-dialog-title" className="text-lg font-semibold">{pending.title}</h2>
        {pending.description && (
          <div className="text-sm text-neutral-300">{pending.description}</div>
        )}

        {pending.mode.kind === 'typed' && (
          <div>
            <label className="block text-xs text-neutral-400 mb-1">
              Type <span className="font-mono text-amber-400">{pending.mode.expected}</span> to confirm
            </label>
            <input
              autoFocus
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder={pending.mode.placeholder}
              className="w-full bg-neutral-800 rounded px-3 py-2 text-sm font-mono focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
            />
          </div>
        )}

        {pending.mode.kind === 'enum_select' && (
          <select
            autoFocus
            value={selectValue}
            onChange={(e) => setSelectValue(e.target.value)}
            className="w-full bg-neutral-800 rounded px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
          >
            {pending.mode.options.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        )}

        {pending.mode.kind === 'json' && (
          <div>
            <textarea
              autoFocus
              value={jsonText}
              onChange={(e) => {
                setJsonText(e.target.value);
                if (!e.target.value.trim()) { setJsonError(null); return; }
                try { JSON.parse(e.target.value); setJsonError(null); }
                catch (err) { setJsonError((err as Error).message); }
              }}
              placeholder={pending.mode.placeholder ?? '{"key":"value"}'}
              rows={8}
              className="w-full bg-neutral-800 rounded px-3 py-2 text-sm font-mono focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
            />
            <div className="mt-1 text-xs">
              {jsonError ? (
                <span className="text-red-400">invalid JSON: {jsonError}</span>
              ) : jsonText.trim() ? (
                <span className="text-green-400">valid JSON</span>
              ) : (
                <span className="text-neutral-500">paste the replacement response body</span>
              )}
            </div>
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <button
            onClick={() => close({ confirmed: false })}
            className="bg-neutral-800 hover:bg-neutral-700 rounded px-3 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500"
          >
            {pending.cancelLabel ?? 'Cancel'}
          </button>
          <button
            onClick={() => {
              if (pending.mode.kind === 'typed') {
                if (input.trim() !== pending.mode.expected) return;
                close({ confirmed: true, value: input.trim() });
              } else if (pending.mode.kind === 'enum_select') {
                if (!selectValue) return;
                close({ confirmed: true, value: selectValue });
              } else if (pending.mode.kind === 'json') {
                if (!jsonText.trim() || jsonError) return;
                try {
                  const parsed = JSON.parse(jsonText) as Record<string, unknown>;
                  close({ confirmed: true, value: parsed });
                } catch {
                  // guarded above — silently refuse.
                }
              } else {
                close({ confirmed: true });
              }
            }}
            disabled={
              (pending.mode.kind === 'typed' && input.trim() !== pending.mode.expected) ||
              (pending.mode.kind === 'enum_select' && !selectValue) ||
              (pending.mode.kind === 'json' && (!jsonText.trim() || !!jsonError))
            }
            className={
              (pending.mode.kind === 'plain' && pending.mode.destructive === false)
                ? 'bg-amber-500 text-neutral-950 rounded px-3 py-1.5 text-sm font-medium disabled:opacity-40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-900'
                : 'bg-red-600 hover:bg-red-500 text-white rounded px-3 py-1.5 text-sm font-medium disabled:opacity-40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-900'
            }
          >
            {pending.confirmLabel ?? 'Confirm'}
          </button>
        </div>
      </div>
    </div>
  ) : null;

  return { ask, dialog };
}
