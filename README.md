# NYC Side Quests — Prompt Chain Studio

Week 8's separate Next.js/Vercel app. Repository: https://github.com/TianisJiao/tianis-prompt-chain-tool. It uses the existing shared Supabase database and Google OAuth provider. The rating app and Week 7 office are preserved.

## What works

- Google login plus a live database `profiles.is_superadmin` check on every studio page and every server action. RLS independently denies ordinary users, anonymous users, non-Google identities, and revoked admins. No service-role key.
- Create/update/delete chains. Create/update/remove steps, and reorder with keyboard-accessible up/down buttons. Save applies the entire sequence atomically; revisions prevent silently overwriting another editor's changes. Removing a step in the editor takes effect when Save is clicked.
- Zero-step drafts and sequences of 1–6 steps. Each step chooses an enabled OpenAI model from the existing Week 7 model/provider tables, its own instructions, and original brief / previous text output / original image plus previous text input. The first previous-output step uses the original brief.
- A real OpenAI Responses call per step, with bounded tokens and a 45-second timeout per call. Every step is a separate authenticated server request, so a six-step chain does not need one long-running Vercel request. Prepare a generation, open it, and click Run. A new click resumes only completed, saved progress; an in-flight or unconfirmed step is never automatically retried.
- Immutable snapshots of the exact chain revision, step order, model IDs and instructions for each run. Outputs, per-step input/output text, status, token usage, latency, and provider response ID are persisted. No API key or image bytes are stored in prompts.
- Generated text/captions are the AI media. A gallery can show works for one chain or all chains, with the original input photo when present. Deleting a chain preserves run snapshots and generated works. The studio does not automatically publish experimental outputs to the public rating gallery.
- Light, dark, and system appearance modes, persisted locally; responsive layout, accessible form labels, focus outlines, reduced-motion support.

The new `studio_*` tables and private `studio-inputs` Storage bucket keep editable experiments separate from Week 7's fixed two-step production prompt chains/mix. No existing table or function is replaced. Existing media, votes, profiles, and the public generator remain unchanged.

## Setup

1. Apply **only** `supabase/week8-studio.sql` in the existing shared Supabase SQL Editor after Week 7. It is rerunnable. Do not run `tests/fixtures/*.sql` against production.
2. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and server-only `OPENAI_API_KEY` in the new Vercel project, using the same existing database. Do not use a service-role key or commit `.env.local`. The model is selected in each step; `OPENAI_MODEL` is unused in this app.
3. Import this new repository into a **new** Vercel project named `tianis-prompt-chain-tool`.
4. In the same Supabase project's Authentication → URL Configuration, add the new production URL and latest commit-specific URL with exact `/auth/callback` paths. Keep all existing app redirects and the existing Site URL. The Google provider's Supabase callback is unchanged.
5. Keep application-level Google/admin checks enabled. Disable Vercel Deployment Protection for the assignment so visitors can reach the application's login wall in incognito.

Local use: `npm ci`, configure `.env.local` from `.env.example`, then `npm run dev`. `OPENAI_API_KEY` is never included in client code. Private photos are sent to OpenAI only when an image step runs; prompts and all outputs are visible only to Google administrators.

## Usage and limits

Create a chain → use the image/angle/five-captions starter (or add steps) → Save → upload a photo/add a brief → Prepare a generation → Open run → Run this chain. Each paid step is saved before the next starts. Keep the tab open. When interrupted, inspect the saved status before continuing or starting again. A stuck lease is deliberately not reclaimed: this avoids unknowingly repeating a charged call whose outcome is unknown. Create a new run only after reviewing the previous attempt.

Limits: six steps, 6,000 characters of instructions per step, 4,000-character brief, 2 MB PNG/JPEG/WebP inputs, ten prepared runs per administrator per UTC day, 1,200 output tokens per call. Empty drafts are allowed; generation requires at least one step and a brief or photo. The tool returns text media, not generated images/videos. Only OpenAI Responses is currently supported.

Editing a chain does not modify historical snapshots. Model disablement blocks new runs; existing runs retain their selected model snapshot. Another administrator can view runs but only the initiating administrator can execute them. Admin revocation takes effect at the next protected operation. Uploaded inputs are retained with the run, including failed attempts; no broad Storage delete policy is granted.

## Validation

```sh
npm run lint
npm run test:runner
npm run test:rls
npm run test:auth
npm run build
```

Tests run the actual migrations in local PGlite and exercise chain/step CRUD, reordering, conflict rejection, preserved historical runs, image policies, sequential leased writes, failures and admin revocation. The actual model runner is tested with mocked provider responses; auth session responses are mocked. These checks do not prove real OAuth, production Supabase, paid model output or browser interactions work.

Before submission verify live chain creation/edit/reordering/deletion, two real generations before/after an edit, the filtered gallery and per-step traces, all appearance modes after refresh, incognito login walls, ordinary-user denial, and all three latest commit-specific Vercel links. Week 7's remaining production CRUD checks should also be completed. Permanent deletion tests should use an explicitly disposable test chain.
