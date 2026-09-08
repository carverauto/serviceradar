## 1. Device detail loading
- [x] 1.1 Add explicit interface and flow availability states and stable navigation loading affordances.
- [x] 1.2 Move same-device interface and flow inventory loads off the LiveView process.
- [x] 1.3 Split favorite-interface metric loading from interface inventory loading.
- [x] 1.4 Bound device flow inventory queries to the recent flow window.

## 2. Diagnostic correctness
- [x] 2.1 Correct CPU overall/core SRQL error attribution and add regression coverage.

## 3. Anomaly lifecycle UX
- [x] 3.1 Project opening and resolution reasons separately for anomaly episodes.
- [x] 3.2 Show resolved lifecycle state, plain-language merged-flap help, and documentation links in the detail modal.
- [x] 3.3 Add component and data regression coverage for cleared episodes.

## 4. Verification
- [x] 4.1 Run focused LiveView/data tests and OpenSpec strict validation.
- [x] 4.2 Run formatter and Elixir quality checks for web-ng.
