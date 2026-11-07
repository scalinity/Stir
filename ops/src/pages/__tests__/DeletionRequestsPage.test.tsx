import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { callAdmin } from '../../lib/api';
import DeletionRequestsPage from '../DeletionRequestsPage';

vi.mock('../../lib/api', () => ({ callAdmin: vi.fn() }));

const pendingRows = [
  {
    id: 'request-first',
    canonical_user_key_hash: 'a1b2c3d4-first-user',
    state: 'pending',
    requested_at: '2026-11-06T12:00:00Z',
    approved_at: null,
    started_at: null,
    failure_reason: null,
  },
  {
    id: 'request-second',
    canonical_user_key_hash: 'e5f6a7b8-second-user',
    state: 'pending',
    requested_at: '2026-11-06T12:30:00Z',
    approved_at: null,
    started_at: null,
    failure_reason: null,
  },
];

function renderWithProviders() {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <DeletionRequestsPage />
    </QueryClientProvider>,
  );
}

function approvalCalls() {
  return vi.mocked(callAdmin).mock.calls.filter(([action]) => action === 'deletion_requests.approve');
}

beforeEach(() => {
  vi.mocked(callAdmin).mockReset();
  vi.mocked(callAdmin).mockResolvedValue({ rows: [], total_count: 0 });
});

describe('DeletionRequestsPage', () => {
  it('renders the heading', () => {
    renderWithProviders();
    expect(screen.getByRole('heading', { name: /Deletion Requests/i })).toBeInTheDocument();
  });

  it('shows the empty state after the query resolves', async () => {
    renderWithProviders();
    expect(await screen.findByText(/No deletion requests in this filter/i)).toBeInTheDocument();
  });

  it('cancels a pending deletion without approving it and restores focus', async () => {
    vi.mocked(callAdmin).mockResolvedValue({ rows: pendingRows, total_count: pendingRows.length });
    const user = userEvent.setup();
    renderWithProviders();
    const trigger = (await screen.findAllByRole('button', { name: 'Approve deletion' }))[0];
    await user.click(trigger);
    const dialog = screen.getByRole('dialog', { name: 'Approve deletion request?' });
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
    expect(approvalCalls()).toEqual([]);
  });

  it('keeps approval disabled for an incorrect confirmation', async () => {
    vi.mocked(callAdmin).mockResolvedValue({ rows: pendingRows, total_count: pendingRows.length });
    const user = userEvent.setup();
    renderWithProviders();
    await user.click((await screen.findAllByRole('button', { name: 'Approve deletion' }))[0]);
    const dialog = screen.getByRole('dialog');
    const input = within(dialog).getByRole('textbox', { name: /Type a1b2c3d4 to confirm/i });
    await user.type(input, 'e5f6a7b8');
    const approve = within(dialog).getByRole('button', { name: 'Approve' });
    expect(approve).toBeDisabled();
    await user.click(approve);
    expect(approvalCalls()).toEqual([]);
  });

  it('approves exactly the selected request and refreshes the pending list', async () => {
    let rows = [...pendingRows];
    vi.mocked(callAdmin).mockImplementation(async (action, params) => {
      if (action === 'deletion_requests.approve') {
        const id = (params as { id: string }).id;
        rows = rows.filter((row) => row.id !== id);
        return { ok: true };
      }
      return { rows, total_count: rows.length };
    });
    const user = userEvent.setup();
    renderWithProviders();
    await user.click((await screen.findAllByRole('button', { name: 'Approve deletion' }))[1]);
    const dialog = screen.getByRole('dialog');
    await user.type(within(dialog).getByRole('textbox'), 'e5f6a7b8');
    await user.click(within(dialog).getByRole('button', { name: 'Approve' }));
    await waitFor(() => {
      expect(approvalCalls()).toEqual([
        ['deletion_requests.approve', { id: 'request-second' }],
      ]);
      expect(screen.queryByText('e5f6a7b8-second-user')).not.toBeInTheDocument();
    });
    expect(screen.getByText('a1b2c3d4-first-user')).toBeInTheDocument();
  });

  it('shows an approval failure and keeps the request available', async () => {
    vi.mocked(callAdmin).mockImplementation(async (action) => {
      if (action === 'deletion_requests.approve') throw new Error('Approval unavailable');
      return { rows: pendingRows, total_count: pendingRows.length };
    });
    const user = userEvent.setup();
    renderWithProviders();
    await user.click((await screen.findAllByRole('button', { name: 'Approve deletion' }))[0]);
    const dialog = screen.getByRole('dialog');
    await user.type(within(dialog).getByRole('textbox'), 'a1b2c3d4');
    await user.click(within(dialog).getByRole('button', { name: 'Approve' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Approval unavailable');
    expect(approvalCalls()).toEqual([
      ['deletion_requests.approve', { id: 'request-first' }],
    ]);
    expect(screen.getByText('a1b2c3d4-first-user')).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'Approve deletion' })[0]).toBeEnabled();
  });
});
