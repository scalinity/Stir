import { Route, Routes, Navigate } from 'react-router-dom';
import { useAdminSession } from './hooks/useAdminSession';
import LoginPage from './pages/LoginPage';
import AppShell from './components/AppShell';
import DashboardPage from './pages/DashboardPage';
import UsersPage from './pages/UsersPage';
import FlaggedOutputsPage from './pages/FlaggedOutputsPage';
import CostAnomaliesPage from './pages/CostAnomaliesPage';

export default function App() {
  const { session, loading } = useAdminSession();

  if (loading) {
    return <div className="min-h-screen flex items-center justify-center text-neutral-400">Loading…</div>;
  }
  if (!session) {
    return <LoginPage />;
  }

  return (
    <Routes>
      <Route element={<AppShell session={session} />}>
        <Route index element={<DashboardPage />} />
        <Route path="users" element={<UsersPage />} />
        <Route path="flagged" element={<FlaggedOutputsPage />} />
        <Route path="anomalies" element={<CostAnomaliesPage />} />
        <Route path="voice" element={<DeferredPage page="Voice Sessions" />} />
        <Route path="flags" element={<DeferredPage page="Feature Flags" />} />
        <Route path="prompts" element={<DeferredPage page="Prompt Versions" />} />
        <Route path="audit" element={<DeferredPage page="Audit Log" />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

function DeferredPage({ page }: { page: string }) {
  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">{page}</h1>
      <p className="text-neutral-400 text-sm">
        Page scaffolded; backend action already shipped in Phase 2. Full UI lands in step 9 polish.
      </p>
      <p className="text-neutral-500 text-xs mt-4">
        Backend call: <code className="text-neutral-300">POST /v1/ops/admin {`{action: '${page.toLowerCase().replace(/ /g, '_')}.list', params: {...}}`}</code>
      </p>
    </div>
  );
}
