// SCA-82 — global test setup for ops SPA.
//
// * @testing-library/jest-dom adds matchers (toBeInTheDocument, etc.)
// * Vitest auto-cleans React Testing Library between tests when
//   afterEach is registered; we let RTL's auto-cleanup hook on import.

import '@testing-library/jest-dom/vitest';
