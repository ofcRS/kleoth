# Roadmap and notes

Ideas and planned work that are not in progress yet. Newest decisions first. What already shipped is
in `CHANGELOG.md`; the state of work in flight is in `CLAUDE.md` → State.

## Next

- **A meeting goes to the agent thread when it is finished.** After the summary is written, Kleoth
  hands the transcript and the summary to a receiver, so the task tracker updates itself instead of
  by hand. The receivers are the development virtual machines (one per Mac), each running T3 Code
  with a "meeting" thread; `t3 thread send <thread> -` takes a message on stdin. Open: the thread on
  each machine, which Mac sends to which machine, and the delivery (a command Kleoth runs after a
  meeting, or an HTTP webhook with a small receiver). Settings → Integrations, a test button, retry,
  "Send again" on a meeting.
- **`kleoth mcp`.** A stdio MCP server over the meetings on disk (list, read a transcript, read a
  summary), after the push above.

## Later

- **A self-hosted cloud.** The front end on the user's own virtual machine, everything routed and
  scraped through the back end; used to synchronize between devices, and more. Not a priority
  (2026-11-18). Design first: what syncs (meetings only, or dictations, settings and audio too), one
  user or several, how the Macs authenticate.
- **A microphone option that follows the call app's input** (`kAudioProcessPropertyDevices`,
  unprobed), for a headset that connects badly.
- **A Notification Center notice for an update.** Today the notice is in the app only; this needs a
  new permission prompt.
- Back up the "Kleoth Self-Signed" certificate (the update key is in 1Password since 2026-11-17).
- Push the Homebrew tap.
