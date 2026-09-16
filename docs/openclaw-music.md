# OpenClaw music contract

## Purpose and boundary

This is an asynchronous, narrow music-acquisition workflow. Its path is:

`OpenClaw wrapper -> JSON ledger and serialized worker -> MusicBrainz -> selected slskd or Streamrip retrieval -> validation -> stock beets -> existing mpdupdate`

Each slskd job gets its own `openclaw/<job UUID>` destination. A Streamrip job instead has a private native runtime below `/volume1/Media/ImportMusic/Streamrip`; its private config, databases, and output are never generic beets watch inputs. Downloaded files are validated and staged, then the existing stock beets configuration, database, and library import the resolved release while holding the shared beets lock. Existing beets mpdupdate is the MPD notification mechanism.

The only executable an agent may call is:

```
/etc/profiles/per-user/tunnel/bin/openclaw-music
```

Never call the slskd API, raw `beet import`, arbitrary shell commands, or an alternate music tool. Do not invoke `worker`: it is reserved for the systemd user service.

## Invocation protocol

Every call has exactly one subcommand, exactly one UTF-8 JSON object on standard input, and one JSON object on standard output. Use schema `1`. Input is limited and rejects unknown/duplicate fields.

```sh
printf '%s\n' '<JSON>' | /etc/profiles/per-user/tunnel/bin/openclaw-music SUBCOMMAND
```

### Supported agent commands

`resolve` (no ledger mutation):

```json
{
  "schema": 1,
  "artist": "Artist",
  "release": "Album",
  "edition": "optional text or null",
  "medium": "optional text or null",
  "include_live": false,
  "include_compilations": false
}
```

`submit` (create or retrieve an idempotent ledger job):

```json
{
  "schema": 1,
  "idempotency_key": "new-random-key",
  "artist": "Artist",
  "release": "Album",
  "quality_profile": "lossless-preferred",
  "backend": "slskd",
  "edition": "optional text or null",
  "medium": "optional text or null",
  "include_live": false,
  "include_compilations": false
}
```

`quality_profile` is optional and is either `lossless` or `lossless-preferred`. The installed default is `lossless-preferred`. `backend` is optional: omit it (or use `slskd`) for the existing slskd path; use `streamrip` only for an explicit Qobuz retrieval. There is no automatic cross-backend fallback.

`choose` (only values returned in the current candidate set):

```json
{
  "schema": 1,
  "job_id": "canonical-uuid",
  "candidate_set_id": "returned-set-id",
  "candidate_id": "returned-candidate-id",
  "revision": 3
}
```

`status` and `retry`:

```json
{ "schema": 1, "job_id": "canonical-uuid" }
```

The parser also supports `worker` with exactly `{"schema":1}`, but it is service-reserved and must not be used by an agent.

## Result and exit contract

Successful command handling exits `0`, including a `status` response for a job in `failed` or `needs_review`. Job state is carried in JSON; do not infer it from process exit status alone.

CLI-level errors use this envelope:

```json
{
  "schema": 1,
  "operation": "submit",
  "state": "error",
  "error": { "code": "invalid_input", "message": "..." },
  "retryable": false
}
```

Stable process exit codes are: `2` `invalid_input`; `3` `unknown` or `backend_not_found`; `4` `conflict`; `5` `temporary_unavailable` or `backend_transient` (retryable); `6` `configuration` or `internal_error`; `7` `backend_permanent` or `beets_no_import`; `8` `backend_uncertain`.

Normal job responses include `schema`, `operation`, `state`, `job_id`, `revision`, `retryable`, `resume_phase`, and `integration_required`. When available they also include:

- `resolved_release` (public title/artist/date/country/media/track count),
- `candidate_set` and `candidate_revision`,
- `selected_source`, `selected_quality`, and `track_count`,
- `import_receipt` and `final_library_path`,
- `mpd_result`, and
- `error` (including stable code/message and, for review states, manual action).

## Request and choice rules

`artist` and `release` are required non-blank strings. `edition` and `medium` are optional text constraints. `include_live` and `include_compilations` are optional booleans and default to `false`.

“Latest” means the newest eligible MusicBrainz **Album** release group whose release-date interval is not after the job's frozen `as_of` time. Live and compilation secondary types are excluded unless explicitly included. Ambiguous artist, release-group, edition, or source/quality decisions are returned as `needs_choice`; they are never guessed.

Generate a new random `idempotency_key` for each distinct user intent. Reuse that same key only when retrying delivery of the same `submit` request. Reusing it with a changed request produces a `conflict` error. Record the returned `job_id` immediately.

For a candidate response, present the returned `candidate_set.stage` and its public candidates to the user (names/disambiguation, release date/media, or source quality as applicable). Ask for a selection. Send the exact returned `candidate_set.id`, candidate `id`, and `candidate_set.revision`; never manufacture or reuse an old ID/revision. A stale or different choice conflicts.

### Streamrip rules

Streamrip is Qobuz-only. It requests quality tier 3, but decoded media and the frozen MusicBrainz manifest remain the authoritative lossless/attribution checks. Its search metadata is discovery text, not edition or quality proof; even a singleton Streamrip result always requires the opaque, revision-checked choice flow.

The protected master config is the authoritative credential source. For each explicit Streamrip job, the worker copies the required Qobuz fields into a private per-job config; that copy contains secret material and persists for diagnosis under 0600 files and 0700 runtime directories. The fixed-argv restricted launcher can write only the current job's native runtime; it cannot see the live master config, beets configuration/database, ledger, validated staging, library, or host home/SSH paths. It does mount the entire Nix store read-only, so non-secret generated Nix artifacts can be visible; credentials must never enter the store. Provider IDs, private config/runtime paths, database rows, raw stderr, and private workflow state are never agent-visible.

Never replay an unacknowledged mutating download or import invocation in `calling`; timeout, nonzero exit, partial/ambiguous evidence, and edition-description conflicts are review-required and never sent to beets. Read-only Streamrip search recovery may be retried only by its bounded worker rules. Recovery from an uncertain mutation is human inspection of the isolated job followed, only after confirmed cleanup, by a new request and idempotency key.

The Streamrip backend is optional. When it is enabled, all three adapter values (launcher, runtime root, and master credentials) are mandatory. Missing or malformed master credentials fail only an explicit Streamrip job; slskd and `status` remain usable.

## State and polling

States are `queued`, `resolving`, `needs_choice`, `searching`, `downloading`, `validating`, `ready`, `importing`, `indexing`, `succeeded`, `failed`, and `needs_review`.

The user timer runs on boot and approximately every 12 seconds after the previous worker run. Do not block a conversation waiting for a transition. Poll `status` about every 15–30 seconds, or after the user has answered a choice. `succeeded`, `failed`, and `needs_review` are terminal. There is no cancellation command.

## Recovery guide

| Condition                                      | Agent action                                                                                                                                                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `needs_choice`                                 | Show the current candidates and ask the user. Call `choose` only with their exact returned IDs/revision.                                                                                             |
| `failed` with `retryable:true`                 | Call `retry` once with the job UUID, then resume polling.                                                                                                                                            |
| `failed` with `error.code:"transfer_rejected"` | All exact batch transfers were terminally rejected before any bytes downloaded. Wait or change source, then submit a new request with a new idempotency key. Do not call `retry` or reuse the batch. |
| `failed` without retryability                  | Report `error.code`/`error.message`; ask the user how to proceed.                                                                                                                                    |
| `needs_review`                                 | Never blindly retry. Report the bounded error and `manual_action`; ask the user/human operator. `retry` is not a recovery path for this state.                                                       |
| `beets_no_import`                              | Inspect the existing beets import log, validated staging directory, and library with a human operator. Do not run raw beet yourself.                                                                 |
| uncertain queue/import (`backend_uncertain`)   | Do not replay the mutation. Report it as review-required. In particular, a `calling` beets import without normal acknowledgement is not auto-completed.                                              |
| unknown job                                    | The UUID is not in this ledger; ask for the correct UUID or submit a new user intent.                                                                                                                |
| idempotency conflict                           | Do not alter the existing key/request. Use the original exact request/key for delivery retry, or obtain a new user intent and a new random key.                                                      |

After confirmed manual cleanup, submit a new request with a **new** idempotency key. Do not claim that cleanup, retry, or beets recovery happened automatically.

For automatically selected sources, up to five distinct peers are tried in frozen fastest-first order. A new slskd batch UUID is used for each peer while the job UUID remains the download destination. Manual source choices remain single-peer plans. Fully successful batches proceed normally. Only an exact current-batch `Completed, Rejected` result with zero transferred bytes and one backend attempt advances to the next peer; mixed, partial, stale, ambiguous, unresolved, or uncertain results require review. After the final clean rejection, the job is non-retryable `failed` with `error.code:"transfer_rejected"`; wait or change source and submit a new request with a new idempotency key.

## Security rules

- Send JSON only; never pass user-supplied paths, URLs, command strings, beet options, or slskd options.
- Do not request, expose, copy, or summarize credentials, secret files, or raw service logs in prompts.
- Do not bypass the wrapper or use an alternate beets configuration/database.
- The wrapper fixes all trusted runtime paths and scrubs ambient environment variables.
- Streamrip credentials originate in `/home/tunnel/.config/streamrip/config.toml`; private 0600 per-job config copies also contain them for retained diagnosis. Never put credentials in JSON, Nix, the Nix store, or logs.

## Example: Steve Lacy

Use placeholders rather than inventing IDs from a live service.

1. Generate `KEY_1` and submit:

```json
{
  "schema": 1,
  "idempotency_key": "KEY_1",
  "artist": "Steve Lacy",
  "release": "Gemini Rights",
  "quality_profile": "lossless-preferred",
  "include_live": false,
  "include_compilations": false
}
```

Suppose the response is `{"state":"queued","job_id":"JOB_UUID",...}`. Store `JOB_UUID` and poll:

```json
{ "schema": 1, "job_id": "JOB_UUID" }
```

2. If polling returns `needs_choice` with:

```json
{
  "candidate_set": {
    "id": "SET_ID",
    "stage": "edition",
    "revision": 7,
    "candidates": [
      {
        "id": "CANDIDATE_A",
        "title": "Gemini Rights",
        "date": "...",
        "media": ["..."]
      },
      {
        "id": "CANDIDATE_B",
        "title": "Gemini Rights",
        "date": "...",
        "media": ["..."]
      }
    ]
  }
}
```

show those editions to the user. After their answer, send:

```json
{
  "schema": 1,
  "job_id": "JOB_UUID",
  "candidate_set_id": "SET_ID",
  "candidate_id": "CANDIDATE_A",
  "revision": 7
}
```

Further ambiguity is handled the same way. On success, a response eventually has `state:"succeeded"`, an `import_receipt`, `final_library_path`, and:

```json
{ "success": true, "mechanism": "beets-mpdupdate", "verified": false }
```

If instead it reaches `needs_review` with `error.code:"beets_no_import"`, report that the import needs human inspection of the existing beets log/staging/library. Do not retry it or issue another import. After cleanup is confirmed, obtain a new user intent/key and submit again.

## Operational limitations and troubleshooting paths

This depends on Soulseek availability and complete matching source files; MusicBrainz can require user disambiguation. A MusicBrainz HTTP 503 means temporary throttling or unavailability, not that MusicBrainz is broken. The wrapper makes one bounded retry of the same read-only request, then durable worker backoff is authoritative; a later successful resolution clears the stale transient status. It is not a peer-fallback condition. MPD notification is recorded as `beets-mpdupdate` with `verified:false` until externally observed. There is no custom beets plugin and no second beets database.

Trusted paths for a human operator are:

- ledger: `/home/tunnel/.local/state/openclaw-music`
- validated staging: `/volume1/Media/ImportMusic/OpenClaw`
- slskd downloads/batches: `/volume1/Media/ImportMusic/slskd/openclaw`
- library: `/volume1/Media/Music`
- beets config/lock: `/home/tunnel/.config/beets/config.yaml` and `/home/tunnel/.config/beets/.import.lock`
- Streamrip protected master config: `/home/tunnel/.config/streamrip/config.toml`
- Streamrip private native runtime: `/volume1/Media/ImportMusic/Streamrip`

For a Streamrip review, a human operator inspects only the isolated runtime and public job status. Do not expose provider identifiers or raw tool output to an agent, and do not manually import native output. The existing beets receipt, shared import lock, and mpdupdate behavior are unchanged.

## Controlled live-test policy

Phase 2 wiring and offline checks are not live-provider approval. Any controlled Qobuz retrieval-only test disables or replaces the production importer and makes both the production beets database/config mutation surface and final library unavailable for writes; making only the library read-only is insufficient. Never duplicate the recovered Steve Lacy release. A first production import requires a separately approved release known to be absent from beets, with a separate approval before enabling writes. The validated Bubblewrap artifact is the repo-pinned 0.11.2 build, not an independently discovered unstable 0.12.0 package.

## Suggested OpenClaw skill workflow

```text
on music request:
  create random key for this user intent
  submit JSON; store job_id
  loop with conversational polling (15–30 seconds):
    status(job_id)
    if needs_choice:
      present only returned candidates; get user decision
      choose(exact set id, candidate id, revision)
    if succeeded:
      report resolved release, selected quality, final paths, and mpd_result
      stop
    if failed and retryable:
      retry(job_id) once; continue polling
    if failed or needs_review:
      report error/manual_action; ask user or human operator
      stop
```
