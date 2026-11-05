# Plan: Support the Max → Max/Ultra rename and the removed 5-hour limit

## What changed (as of 2026-10-30)

- Plans renamed: **Max 5x → Max** ($100), **Max 20x → Ultra** ($200). Prices and weekly limits unchanged.
- **Verified Ultra accounts have no 5-hour limit.** Unverified Ultra accounts keep a temporary 5-hour limit until auto-verified. Max still has the 5-hour limit.
- Ultra has a weekly all-models limit **plus a separate weekly Fable limit**.

Sources: [What is the Ultra plan?](https://support.claude.com/en/articles/17728952-what-is-the-ultra-plan), [Use Claude Code with your Pro, Max, or Ultra plan](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-max-or-ultra-plan), [@claudeai announcement](https://x.com/claudeai/status/2116220869479428500).

## What the API returns now (live call, Ultra account, 2026-11-05)

- `five_hour`: `null`. `seven_day_opus` / `seven_day_sonnet`: `null`.
- `seven_day`: still present (`utilization: 3.0`, `resets_at`).
- New **`limits`** array, self-describing:
  ```json
  {"kind": "weekly_all", "group": "weekly", "percent": 3, "severity": "normal",
   "resets_at": "...", "scope": null, "is_active": true}
  {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
   "resets_at": "...", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
   "is_active": false}
  ```
- The Fable limit appears **only** in `limits`; there is no `seven_day_fable` bucket.
- Credentials still say `subscriptionType: "max"`. Only `rateLimitTier: "default_claude_max_20x"` tells you it's Ultra.
- Not observed: the `kind`/`group` used for a 5-hour entry in `limits`, because this account has none. We have to tolerate whatever it turns out to be.

## What's broken in the app today

1. **The menu bar shows `--%` for verified Ultra users.** `UsageService.menuBarLabel` reads only `fiveHour.utilization`. That's nil, and `hasAnyUsageData` is true (because of `sevenDay`), so it falls through to `--%`. This is the headline bug.
2. The Fable weekly limit is never shown.
3. The plan badge on main shows "Max 20x" instead of "Ultra".
4. The Opus/Sonnet bars are dead for current plans. That's harmless, but they're legacy.
5. The docs say "Pro/Max" throughout.

## Design

- **Decoding contract for `limits`** (each case gets a test):
  - A missing or `null` `limits`, or one of the wrong type, gives an empty array. It never fails the response.
  - Each entry is decoded on its own; a malformed entry is dropped and its neighbours are kept.
  - `kind`, `group` and `severity` are kept as raw strings, so unknown values survive.
  - `percent` is clamped to 0...100 with the same `clampUtilization` used by `UsageBucket`, both when decoding and in the memberwise init.
  - A null `scope` is allowed. Keep `scope.model.id`, `scope.model.display_name` and `scope.surface`, not just the display name.
  - A missing `is_active` is treated as active. An invalid `resets_at` makes it nil but keeps the entry, which is more lenient than `UsageBucket`, on purpose.
- **Normalised rows (`UsageRow`)** are the single source for both the popover and the menu bar headline. They're built by one pure function, `usageRows(for: UsageResponse) -> [UsageRow]`. Fields: `id`, `label`, `percent`, `resetsAt`, `isActive`.
  - Start from the `limits` entries.
  - Then **merge in each legacy bucket unless an equivalent modern row exists**. Equivalent means the same breadth of scope. Legacy buckets cover every surface, so only a modern row **with no surface** can match one: `seven_day` ↔ `weekly_all` with a null scope; `seven_day_opus`/`seven_day_sonnet` ↔ `weekly_scoped` whose model is Opus/Sonnet **and** whose surface is null. A surface-specific modern row is a distinct limit and never suppresses a legacy bucket; `five_hour` has no known equivalent, so it's always merged when present. Unrelated non-weekly entries (e.g. a future daily limit) never suppress a legacy bucket, and a partly decoded array can't hide a legacy bucket that's still present.
  - Legacy rows count as active.
  - Order: 5-hour, weekly-all, then scoped rows by label, then unknown kinds.
- Row labels: `weekly_all` → "Weekly (All Models)"; `weekly_scoped` → "<model display_name> (Weekly)" (plus " · <surface>" when there's a surface); the legacy 5-hour bucket → "5-Hour Session"; unknown kinds → a humanised `kind`.
- **Stable row ids** come only from content, never from position: `kind`, then `:m=<model id, else display name>` and `:s=<surface>` when present (e.g. `weekly_all`, `weekly_scoped:m=Fable`). Legacy rows use `legacy:five_hour` and so on. If two entries still produce the same id, they can't be told apart, so **collapse them into one row**, with each field merged so the result doesn't depend on order: the maximum `percent`; `isActive` true if any duplicate is active; the earliest non-nil `resets_at`; and the lexicographically smallest rendered label, since entries with the same model id can carry different display names. Collapsing that way can only overstate usage, never hide it. Test duplicates (active 80% and inactive 95%) plus another active row at 20%, with differing display names, in both API orders: the merged row is identical both times (95%, active), and auto selects it. Test that each logical row keeps its id when the response is reordered, not merely that the set of ids is unchanged.
- **`hasAnyUsageData`** must count `limits`, not only the legacy buckets. Otherwise a response with only `limits` shows `--%` and "No usage data". Define it as "`usageRows` is non-empty, or extra usage is enabled".
- **Headline for the menu bar is user-selectable** (decided 2026-11-05):
  - The default is **"Highest active (auto)"**: the highest percent across active rows, legacy included. It shows the highest utilization among active limits. **This deliberately changes legacy behavior.** Today the 5-hour bucket always wins and a response with only weekly data shows `--%`, which an existing test enforces (`UsageServiceTests.swift:192`, `menuBarLabelNoFiveHour`). That test is the Ultra bug written down as intended behavior. Slice 2 rewrites it.
  - If there are no active rows but some data, use the highest inactive row. If there are no rows at all, keep the existing `--%` / `!!` behavior.
  - Selection is a separate pure function that returns a row. The existing `formatMenuBarLabel` stays unchanged and formats that row's percent.
  - The user can **pin one specific row** from a picker in the popover, e.g. pin "Weekly (All Models)" after maxing out Fable and switching to Opus. The popover still lists every row; only the menu bar number changes. A pinned row is shown even when it's inactive.
  - **If the pinned row is missing from a response,** fall back to auto for display, but **never overwrite the stored choice**, so it comes back when the row reappears. The picker shows it as "(unavailable)".
  - The choice is persisted through an injected `HeadlinePreferenceStore` protocol. Production uses `UserDefaults`; tests, `makeService` and the SwiftUI preview use an in-memory store.
- **Plan name:** `formatPlanBadge` already exists on main (PR #31). Only the 20x label changes, to "Ultra".
- Keep the local 50/80/90 colour thresholds. Server `severity` is only ever `"normal"` in what we've seen, so we can't map it yet. Revisit later.

## Slices (TDD, each one green and committed separately with approval)

1. **Decode `limits`.** Add a fixture from the live response, with real timestamps (it contains no PII). Tests cover every bullet of the decoding contract, including a malformed entry between two valid ones. Files: `Models.swift`, `ModelsTests.swift`.
2. **Rows + auto headline + `hasAnyUsageData`.** These are the pure `usageRows` and `selectHeadline` functions, tested for:
   - The Ultra fixture (`five_hour` null) → `"3%"`.
   - `five_hour` 85 with weekly 40 → `"85%!"`, and weekly 70 above `five_hour` 20 → `"70%"`.
   - Weekly-only legacy → the weekly percent, with `menuBarLabelNoFiveHour` rewritten deliberately.
   - An inactive scoped row at 95 doesn't drive the headline.
   - Legacy merge cases: a partial array, an unrelated daily entry, `seven_day` versus `weekly_all` de-duplication.
   - Unique ids, and the same ids after reordering.
   - `hasAnyUsageData`: `limits` only, cached rows still shown after an error, extra usage only.

   - Legacy merge: a legacy Sonnet bucket plus a surface-specific modern Sonnet row → both rows kept.

   Wire the headline into `UsageService.menuBarLabel`. This isn't released on its own, because the popover still renders only legacy buckets until slice 3.
3. **Popover renders rows.** `ContentView.usageContent` iterates `usageRows` instead of the four hard-coded buckets. Update the preview to the Ultra shape. There's no new logic, so it's covered by slice 2's tests plus a visual check (Ultra fixture: the Fable row shows; no "No usage data" message). **Slices 1–3 together are the 1.0.5 hotfix point.**
4. **Pinned headline.**
   - Extend `selectHeadline` with `HeadlineChoice` (`.auto` or `.pinned(id)`). Tests: pinned `weekly_all` at 3% beats Fable at 100% → `"3%"`; a pinned inactive row is still shown; a missing pin falls back to auto.
   - `UsageService.headlineChoice` is backed by `HeadlinePreferenceStore`. Test the sequence present → missing (falls back to auto; the store is unchanged) → new service instance (the pin is restored) → row reappears (the pin applies), plus switching back to `.auto` (the store is updated).
   - Add the picker to `ContentView`.
5. **Plan name: rename "Max 20x" to "Ultra".** Main already derives the badge from `rateLimitTier` (`formatPlanBadge` in `Formatting.swift`, PR #31): 5x gives "Max" and other multipliers give "Max <n>x". Change the 20x mapping to "Ultra", keep 5x as "Max", and update the existing `FormattingTests` expectations and the preview. Any unrecognised multiplier keeps the "Max <n>x" fallback.
6. **Docs.** README, CLAUDE.md ("Pro/Max" → "Pro, Max, or Ultra", test count, Formatting description), and mark `PLAN.md` sections `[Updated]` as before.
7. **Release.** Bump the version and cut the release through the existing workflow.

## Local install (separate from the release, machine-specific)

After the release: confirm which copy is running (`ps` / `sfltool dumpbtm`), install the new build to `/Applications`, and launch it. Re-toggle Launch at Login and confirm the login item now points at `/Applications`. Only then delete `~/Downloads/ClaudeUsage.app`.

## Risks / open questions

- The undocumented API can change again. That's why decoding is tolerant per entry, and why legacy buckets are merged rather than replaced.
- The 5-hour entry's shape in `limits` is unknown, which is why `five_hour` is always merged from the legacy bucket. If an unverified Ultra or Max account becomes available, capture its response, add it as a fixture, and add the modern ↔ legacy equivalence.
- Headline rule: resolved, auto by default with a user pin (see Design).

## Review log

- 2026-11-05: Codex (paired pane) reviewed the plan with 8 findings, all accepted and folded in above: `hasAnyUsageData`, the legacy-merge rule, the explicit legacy semantics change, rows moved to slice 2, richer ids, the pin persistence sequence, the decoding contract, and local install split out.
- 2026-11-05: Round 2 had 3 blocking findings and 1 nit, all fixed: ids are content-only and indistinguishable entries collapse to the higher percent; legacy equivalence requires a matching (null) surface; the hotfix boundary moved to after slice 3; the "stop you first" wording was softened.
- 2026-11-05: Round 3 had 1 blocking finding, fixed: the duplicate collapse now defines every field (`isActive` = any active) and is order-independent.
- 2026-11-05: Round 4: no blocking findings. 1 nit (the label tie-break) applied. Loop closed.

## Implementation log

- 2026-11-05: Slices 1–6 implemented on branch `ultra-limits` (uncommitted). Codex code review: round 1 had 4 blocking findings (strict scope decoding, exact model-family match, picker visible while a pin is set, id tie-break; a claimed compile bug was a false positive but got simplified), round 2 had 1 blocking finding (identity-less scope objects) plus 2 doc nits, and round 3 was clean. Mutation testing: 64 mutants, 50 killed; tests added for all 13 non-equivalent survivors, re-verified. 205 tests pass.
