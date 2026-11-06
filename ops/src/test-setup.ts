// SCA-82 — global test setup for ops SPA.
//
// * @testing-library/jest-dom adds matchers (toBeInTheDocument, etc.)
// * Vitest auto-cleans React Testing Library between tests when
//   afterEach is registered; we let RTL's auto-cleanup hook on import.

import '@testing-library/jest-dom/vitest';


// jsdom does not implement modal dialog presentation. These shims only
// expose open/closed state; browser focus containment remains native behavior.
Object.defineProperties(HTMLDialogElement.prototype, {
  showModal: {
    configurable: true,
    value(this: HTMLDialogElement) { this.setAttribute('open', ''); },
  },
  close: {
    configurable: true,
    value(this: HTMLDialogElement) { this.removeAttribute('open'); },
  },
});
