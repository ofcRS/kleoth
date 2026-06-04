import { Action, ActionPanel, Detail } from "@raycast/api";
import { useMemo } from "react";
import { listMeetings, readText } from "./lib/kleoth";

/** The most recent meeting's summary, rendered as markdown. */
export default function Command() {
  const latest = useMemo(() => listMeetings().find((m) => m.hasSummary), []);
  const markdown = latest
    ? readText(latest.summaryPath) ?? "_Could not read the summary file._"
    : "## No summaries yet\n\nRecord a meeting from the Kleoth menu bar — its summary will show up here.";

  return (
    <Detail
      markdown={markdown}
      navigationTitle={latest?.title ?? "Latest Summary"}
      actions={
        latest && (
          <ActionPanel>
            <Action.Open title="Open Summary File" target={latest.summaryPath} />
            <Action.CopyToClipboard title="Copy Summary" content={readText(latest.summaryPath) ?? ""} />
            <Action.CopyToClipboard title="Copy Summary Path" content={latest.summaryPath} />
            <Action.ShowInFinder path={latest.dir} />
          </ActionPanel>
        )
      }
    />
  );
}
