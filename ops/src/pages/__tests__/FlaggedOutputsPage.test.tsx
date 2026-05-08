// SCA-82 — smoke test: FlaggedOutputsPage renders without crashing.

import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import FlaggedOutputsPage from '../FlaggedOutputsPage';

vi.mock('../../lib/api', () => ({
  callAdmin: vi.fn().mockResolvedValue({ rows: [], total_count: 0 }),
}));

vi.mock('../../components/ConfirmDialog', () => ({
  useConfirm: () => ({
    ask: vi.fn().mockResolvedValue({ confirmed: false }),
    dialog: null,
  }),
}));

function renderWithProviders() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <FlaggedOutputsPage />
    </QueryClientProvider>,
  );
}

describe('FlaggedOutputsPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(screen.getByRole('heading', { name: /Flagged Outputs/i })).toBeInTheDocument();
  });

  it('renders the state filter buttons', () => {
    renderWithProviders();
    expect(screen.getByRole('button', { name: 'open' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'resolved' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'all' })).toBeInTheDocument();
  });
});
