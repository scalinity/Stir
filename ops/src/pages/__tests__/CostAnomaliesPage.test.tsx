// SCA-82 — smoke test: CostAnomaliesPage renders without crashing
// when the API returns an empty list.

import { describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import CostAnomaliesPage from '../CostAnomaliesPage';

vi.mock('../../lib/api', () => ({
  callAdmin: vi.fn().mockResolvedValue({ rows: [] }),
}));

function renderWithProviders() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <CostAnomaliesPage />
    </QueryClientProvider>,
  );
}

describe('CostAnomaliesPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(screen.getByRole('heading', { name: /Cost Anomalies/i })).toBeInTheDocument();
  });

  it('shows the empty-state message after the query resolves', async () => {
    renderWithProviders();
    await waitFor(() => {
      expect(screen.getByText(/No open anomalies in this filter/i)).toBeInTheDocument();
    });
  });
});
