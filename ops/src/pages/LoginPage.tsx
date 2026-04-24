import { useState } from 'react';
import { supabase } from '../lib/supabase';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [status, setStatus] = useState<'idle' | 'sending' | 'sent' | 'error'>('idle');
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setStatus('sending');
    setErr(null);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) {
      setStatus('error');
      setErr(error.message);
    } else {
      setStatus('sent');
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center p-8">
      <div className="w-full max-w-sm bg-neutral-900 rounded-xl p-8 shadow-xl">
        <h1 className="text-2xl font-semibold mb-1">Stir Ops</h1>
        <p className="text-sm text-neutral-400 mb-6">Admin console — sign in with magic link.</p>

        {status === 'sent' ? (
          <div className="text-sm">
            <p className="mb-2">Check <span className="font-mono">{email}</span> for the sign-in link.</p>
            <p className="text-neutral-500">You can close this tab; the link opens back here.</p>
          </div>
        ) : (
          <form onSubmit={submit} className="flex flex-col gap-3">
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="admin@example.com"
              className="bg-neutral-800 rounded px-3 py-2 outline-none focus:ring-2 focus:ring-amber-500"
              disabled={status === 'sending'}
            />
            <button
              type="submit"
              disabled={status === 'sending' || !email}
              className="bg-amber-500 text-neutral-950 rounded px-3 py-2 font-medium disabled:opacity-50"
            >
              {status === 'sending' ? 'Sending...' : 'Send magic link'}
            </button>
            {err && <p className="text-red-400 text-xs">{err}</p>}
          </form>
        )}

        <p className="text-xs text-neutral-600 mt-6">
          Admin access is gated on <code>ops_admins</code> membership (ADR 0023). Non-admins see an error after sign-in.
        </p>
      </div>
    </div>
  );
}
