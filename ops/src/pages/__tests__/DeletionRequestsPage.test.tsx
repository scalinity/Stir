// SCA-113 — smoke test: DeletionRequestsPage renders without crashing
// when the API returns an empty list.
//
// Mirrors the SCA-82 pattern (CostAnomaliesPage / FlaggedOutputsPage /
// UsersPage / DashboardPage smoke tests). The page lands behind the
// SCA-61 in-app deletion surface; this test pins the render shape so a
// future regression on the heading or the empty-state copy fails CI
// instead of a beta tester.

import { describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import DeletionRequestsPage from '../DeletionRequestsPage';

vi.mock('../../lib/api', () => ({
  callAdmin: vi.fn().mockResolvedValue({ rows: [], total_count: 0 }),
}));

function renderWithProviders() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <DeletionRequestsPage />
    </QueryClientProvider>,
  );
}

describe('DeletionRequestsPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(
      screen.getByRole('heading', { name: /Deletion Requests/i }),
    ).toBeInTheDocument();
  });

  it('shows the empty-state message after the query resolves', async () => {
    renderWithProviders();
    await waitFor(() => {
      expect(
        screen.getByText(/No deletion requests in this filter/i),
      ).toBeInTheDocument();
    });
  });
});
