// SCA-82 — smoke test: UsersPage renders the table headers + tier filter.

import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import UsersPage from '../UsersPage';

vi.mock('../../lib/api', () => ({
  callAdmin: vi.fn().mockResolvedValue({ users: [], total_count: 0, limit: 100, offset: 0 }),
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
      <UsersPage />
    </QueryClientProvider>,
  );
}

describe('UsersPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(screen.getByRole('heading', { name: /Users/i })).toBeInTheDocument();
  });

  it('renders the tier filter dropdown', () => {
    renderWithProviders();
    expect(screen.getByRole('combobox')).toBeInTheDocument();
    expect(screen.getByText('All tiers')).toBeInTheDocument();
  });

  it('renders the search input', () => {
    renderWithProviders();
    expect(screen.getByPlaceholderText(/search canonical_user_key/i)).toBeInTheDocument();
  });
});
