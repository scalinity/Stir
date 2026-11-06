import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useConfirm } from '../ConfirmDialog';

function ConfirmationHarness({ onResult }: { onResult: (confirmed: boolean) => void }) {
  const { ask, dialog } = useConfirm();
  return (
    <>
      <button onClick={async () => {
        const result = await ask({ title: 'Withdraw output', mode: { kind: 'plain' } });
        onResult(result.confirmed);
      }}>Withdraw</button>
      <button>Another action</button>
      {dialog}
    </>
  );
}

describe('useConfirm', () => {
  it('opens a native modal and handles a native Escape cancellation', async () => {
    const showModal = vi.spyOn(HTMLDialogElement.prototype, 'showModal');
    const onResult = vi.fn();
    const user = userEvent.setup();
    render(<ConfirmationHarness onResult={onResult} />);
    const trigger = screen.getByRole('button', { name: 'Withdraw' });
    await user.click(trigger);
    const dialog = screen.getByRole('dialog', { name: 'Withdraw output' });
    expect(dialog.tagName).toBe('DIALOG');
    expect(showModal).toHaveBeenCalledTimes(1);
    expect(within(dialog).getByRole('button', { name: 'Cancel' })).toHaveFocus();
    fireEvent(dialog, new Event('cancel', { cancelable: true }));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
    await waitFor(() => expect(onResult).toHaveBeenCalledWith(false));
    showModal.mockRestore();
  });

  it('resolves a confirmed plain action once', async () => {
    const onResult = vi.fn();
    const user = userEvent.setup();
    render(<ConfirmationHarness onResult={onResult} />);
    await user.click(screen.getByRole('button', { name: 'Withdraw' }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Confirm' }));
    expect(onResult).toHaveBeenCalledTimes(1);
    expect(onResult).toHaveBeenCalledWith(true);
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });
});
