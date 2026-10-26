# Automatic import into a user-selected library

Status: proposal; this change does not enable background Bluetooth activity.

## User experience

The user chooses a writable library folder and enables automatic import. The app shows Paused, Waiting for Bluetooth, Waiting for device, Waiting for phone to disconnect, Importing, Up to date, or Needs attention. VoiceOver must announce meaningful transitions without repeated scan notifications. Closing a window may leave the menu-bar app running; quitting stops the watcher.

Audio and derived transcripts, speaker labels, summaries and action items live under the chosen library. Changing folders opens a separate library without migrating or deleting files. Models and account credentials are separate from the library. A library export must not include private keys or API tokens.

## State machine

Disabled -> WaitingForBluetooth -> Scanning -> MatchingAccountDevice -> Connecting -> Authenticating -> Listing -> Importing -> Idle.

Permission denial enters NeedsAttention. Phone ownership, busy device or recording-in-progress enters Waiting with bounded exponential backoff. Disconnect and sleep cancel transport work and return to Waiting. Only one transport job owns the device link. Manual jobs suspend automatic work. Account changes invalidate identity matching and cached authorization provenance; do not delete historical keys automatically.

## Identity and transfer rules

Compare the complete advertised device serial against the current account inventory before connection. Names, RSSI and cached peripheral IDs are insufficient. Require a unique match or explicit target selection. A signature existing for a serial does not prove account ownership. Cache identity with region/account/public-key fingerprints after successful verification, allowing later offline use.

Read the recording list twice while idle; only transfer stable completed files. Do not use key-clearing commands, regenerate identity, rebind, or delete recordings. Authenticate session and encrypted file data; validate the decoded container and full audio before publishing.

## Storage and idempotency

Use a durable per-library transfer journal keyed by account/device identity and device recording ID. Record advertised size, transfer state, and final content SHA-256. Download into a private temporary file on the same filesystem. An incomplete file never appears as a library recording. After all validation, atomically rename the file and commit metadata. Recover safely if interrupted between these operations. Duplicate advertisements and repeated scans must not create duplicate library items. Changed size/content with a reused recording ID must be treated as a distinct version and surfaced.

Use per-library locking. Validate destination availability and free space before starting. If an external drive or cloud-synced folder becomes unavailable, stop rather than silently falling back to a different location. Original device recordings remain untouched.

## Processing queue

Import and AI processing are separate queues. Local ASR is the default automatic processor until the user chooses otherwise. A cloud provider must have an explicit disclosure/authorization covering automatic uploads, with visible pause and revocation. Preserve original transcripts; write AI summaries, action items and proposed corrections as distinct derived artifacts with source references and model provenance.

## Delivery checklist

- [ ] UI preference and persistent chosen-folder access
- [ ] Account-scoped identity guard and single-device selection
- [ ] Bluetooth watcher, backoff and sleep/wake recovery
- [ ] Stable-recording detection, transfer journal and atomic publish
- [ ] Deduplication and unavailable-folder handling
- [ ] Local processing queue and separate cloud upload authorization
- [ ] Tests: two nearby devices, duplicate discoveries, interrupted transfer, busy/recording device, account switch, permissions, folder loss, restart and sleep/wake
- [ ] Hardware acceptance: source retained, no duplicate import, complete playable audio

No functionality above should be represented as shipped until the corresponding implementation and hardware checks pass.
