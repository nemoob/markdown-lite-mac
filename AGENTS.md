# Repository Rules

- Make the smallest correct change; keep unrelated behavior and files untouched.
- Prefer Swift standard library and native macOS frameworks. Do not add a dependency unless the requirement cannot be met cleanly without it.
- Use English identifiers and public API names. Use concise Chinese comments for business logic, data sources, fallbacks and non-obvious side effects.
- For new or materially changed logic, place concise Chinese comments before nearly every logical statement, branch, field assignment and non-obvious call. Explain the data source, purpose, fallback and effect; do not comment imports, braces or merely repeat Swift syntax.
- Keep parsing, file scanning and other potentially expensive work off the main thread. Measure performance-sensitive changes.
- Preserve user data: use atomic writes, keep encoding metadata, detect external changes and never overwrite silently.
- Every behavior change needs a repeatable SwiftPM test or executable self-check, including failure and recovery paths.
- Build with warnings treated as errors before requesting review.
- Never commit generated `.build/`, `dist/` or unsigned application bundles.
