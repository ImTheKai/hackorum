# Per-Patchset Download — Design

## Problem

The topic show view (`app/views/topics/show.html.slim`) only exposes a
"Download Latest Patchset" button. Threads frequently contain multiple
patchset revisions (v1, v2, v3, …), and reviewers need to fetch any of
them — not only the latest. The sidebar should expose every patchset, with
a link to the originating message and a per-patchset download.

## Goals

- Add a "Show all patchsets" collapsible to the sidebar's Attachments
  section, alongside the existing "Show all attachments" details.
- Each entry: message-number anchor link + smart time + per-patchset
  download icon.
- Preserve the existing "Download Latest Patchset" button as the primary
  affordance.
- Reuse the existing tar.gz construction logic — do not duplicate it.

## Non-Goals

- No filename, line-stat, or attachment-name display per entry (kept
  minimal to match the existing attachments sidebar density).
- No reworking of `is_patch_submission` detection.
- No bulk multi-patchset download.

## Architecture

Three pieces:

1. **New action** `TopicsController#patchsets_sidebar` — turbo frame
   source, returns the ordered patchset list.
2. **New action** `MessagesController#patchset` — builds tar.gz for one
   specific message identified by message id.
3. **Shared builder** extracted from the existing
   `TopicsController#latest_patchset` so both endpoints share one
   implementation.

### Routes

```
GET /topics/:id/patchsets_sidebar   # member, turbo frame source
GET /messages/:id/patchset          # member, per-message tar.gz
GET /topics/:id/latest_patchset     # kept, internally resolves to latest
                                    # patch-submission message and uses
                                    # the shared builder
```

### Sidebar query

`patchsets_sidebar`:

- Loads `@topic.messages.where(is_patch_submission: true)` newest first,
  preloading `:attachments`.
- Builds the topic-wide `@message_numbers` map (full message ordering) so
  each entry can show `#N`.
- Renders `topics/patchsets_sidebar.html.slim` without layout.

### Download endpoint

`MessagesController#patchset`:

- Loads message + topic.
- 404 if `is_patch_submission` is false **or** no patch-submission
  candidate attachments remain.
- Computes the same metadata as today (attachment number among messages
  with attachments, upstream message-id URL).
- Calls the shared `PatchsetArchive.build(message:, topic:)` helper which
  returns the tar.gz bytes plus a suggested filename.
- `send_data` with disposition `attachment` and filename
  `topic-{topic_id}-msg{N}-patchset.tar.gz`.

### Shared builder

`app/lib/patchset_archive.rb` (or `app/services/`, following the
project's existing conventions — check `app/lib` vs `app/services` and
match). Exposes:

```
PatchsetArchive.build(message:, topic:) -> { data:, filename: }
```

Encapsulates: ordering attachments, generating `hackorum.json`
metadata, tar.gz writing. `TopicsController#latest_patchset` is refactored
to find the latest patch-submission message and delegate.

### View

New `app/views/topics/patchsets_sidebar.html.slim`:

```
= turbo_frame_tag "patchsets-sidebar-list" do
  - if @patchset_messages.any?
    ul.patchsets-list
      - @patchset_messages.each do |msg|
        - number = @message_numbers[msg.id]
        li
          = link_to "##{message_dom_id(msg)}",
              class: "patchset-link",
              data: { turbo: false } do
            span.patchset-target = "##{number}"
            span.patchset-date = smart_time_display(msg.created_at)
          = link_to message_patchset_path(msg),
              class: "patchset-download",
              download: "topic-#{@topic.id}-msg#{number}-patchset.tar.gz",
              data: { turbo: false },
              aria: { label: "Download patchset ##{number}" } do
            i.fas.fa-download
  - else
    p No patchsets in this thread
```

`show.html.slim` is updated to add a sibling `details.attachments-details`
right after "Show all attachments", with summary "Show all patchsets" and a
lazy turbo frame to `patchsets_sidebar_topic_path(@topic)`.

## Edge Cases

- Topic with zero patch-submission messages — empty list path renders
  "No patchsets in this thread"; the details element can still be hidden
  by gating on `@has_patches` in `show.html.slim`.
- Message marked as patch submission but all attachments removed — 404
  from `MessagesController#patchset`.
- Merged topic — `set_topic` already redirects in topics show; for the
  message endpoint, derive topic from the message itself (no redirect
  needed since the URL is message-scoped).

## Testing

- Request spec for `topics#patchsets_sidebar`:
  - returns only patch-submission messages
  - ordered newest first
  - empty-state copy renders when none
- Request spec for `messages#patchset`:
  - returns tar.gz with correct filename
  - 404 on non-patch-submission message
  - 404 when patch attachments missing
  - tar.gz contains `hackorum.json` and patch files
- Request spec confirming `topics#latest_patchset` still works after
  refactor (regression).

## Out of scope

- Changing how the latest patchset is highlighted.
- Showing line-change stats per historical patchset (deferred — current
  diff_line_stats decoding cost is non-trivial across many messages).
