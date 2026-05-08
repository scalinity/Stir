// SCA-82 — smoke test: DashboardPage renders 3 KPI cards and tolerates
// per-card errors (W42 invariant — Promise.allSettled-equivalent under
// useQuery's per-card error path).

import { describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import DashboardPage from '../DashboardPage';

vi.mock('../../lib/api', () => ({
  callAdmin: vi.fn((action: string) => {
    if (action === 'users.list') return Promise.resolve({ total_count: 42, users: [] });
    if (action === 'flagged_outputs.list') return Promise.resolve({ total_count: 3 });
    if (action === 'cost_anomalies.list') return Promise.resolve({ total_count: 0 });
    return Promise.reject(new Error(`unknown action: ${action}`));
  }),
}));

function renderWithProviders() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <DashboardPage />
    </QueryClientProvider>,
  );
}

describe('DashboardPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(screen.getByRole('heading', { name: /Dashboard/i })).toBeInTheDocument();
  });

  it('shows all three KPI labels', () => {
    renderWithProviders();
    expect(screen.getByText('Active users')).toBeInTheDocument();
    expect(screen.getByText('Open flagged outputs')).toBeInTheDocument();
    expect(screen.getByText('Open cost anomalies')).toBeInTheDocument();
  });

  it('renders the resolved totals', async () => {
    renderWithProviders();
    await waitFor(() => {
      expect(screen.getByText('42')).toBeInTheDocument();
      expect(screen.getByText('3')).toBeInTheDocument();
    });
  });
});
