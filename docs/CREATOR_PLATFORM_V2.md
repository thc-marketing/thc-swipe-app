# THC Swipe App v2 — Creator Platform Plan

## Goal
Add a mobile-first, free creator feed and creator publishing workflow without replacing the existing swipe/reservation experience.

## Preserve
- `index.html` swipe/discovery UI, favorites and likes
- Live profile API: `https://833d8cc1-thc-live-profiles.thc-girls.workers.dev/`
- Schedule API: `https://thc-schedule-api.thc-girls.workers.dev/`
- Reservation flow and current phone button (03-6233-8163)
- Existing contact links and profile details

## Release sequence

### Phase 1 — secure data foundation (this commit)
- Add Supabase tables for creator profiles, feed posts, post media metadata, and payment entitlement records.
- Enforce row-level security (RLS); clients may read published free posts, creators may manage only their own drafts/posts, and role elevation is never client-controlled.
- Use an explicit approval flag for creator publishing.
- Include schema notes for storage, moderation, and payment webhooks.

### Phase 2 — mobile feed
- Add a Feed destination without replacing Discover.
- Display published free posts in newest-first order with creator name, caption, media, and post date.
- Use responsive image/video rendering, pagination, loading/error/empty states, and accessible controls.
- Do not display private storage paths or expose unpublished content.

### Phase 3 — creator studio
- Both customers and creators may register/sign in; account role is assigned/approved server-side.
- Approved creators can upload media from mobile, preview, save drafts, and publish.
- Validate file type/size, rate-limit publishing, moderate reports, and record consent/ownership confirmation.
- Never treat a hidden button or client-supplied role as authorization.

### Phase 4 — real payments
- Keep the initial feed free, but prepare payment integration only after a provider approves the business and content category.
- Never collect card details in this static page or store payment credentials.
- A trusted server/edge function must create checkout sessions and verify signed webhooks before granting entitlements.
- Paid media must use private storage and short-lived signed URLs; do not rely on front-end hiding.
- Test refunds, chargebacks, failed payments, cancellations, tax/accounting requirements, and Japan legal/provider requirements before launch.

## Required environment/configuration
- Supabase project URL and anon key in the client (anon key is public; RLS is mandatory).
- Supabase Storage bucket for creator media, preferably private for unpublished/restricted media.
- Server-side Supabase service-role key only in a secret manager/edge function; never in this repository or browser code.
- Payment provider credentials and webhook signing secret only in server-side secrets.
- No payment provider or live checkout is configured by this schema.

## Acceptance checklist
- Existing swipe, booking, schedule lookup, and call button remain unchanged.
- Unauthenticated users can read published free posts only.
- A customer cannot insert/update creator records or publish posts.
- An unapproved creator cannot publish.
- A creator cannot edit another creator's posts.
- Payment entitlements can only be written by a trusted server after verified payment events.
- Uploads are restricted by size/type and moderation/report paths exist before public launch.
