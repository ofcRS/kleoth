import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useMemo } from "react";
import { listMeetings, meetingsDir, readText, type Meeting } from "./lib/kleoth";

/** Browse all recorded meetings: open / copy summaries & transcripts. */
export default function Command() {
  const meetings = useMemo(listMeetings, []);

  return (
    <List searchBarPlaceholder="Search meetings…">
      {meetings.length === 0 ? (
        <List.EmptyView
          icon={Icon.Waveform}
          title="No meetings yet"
          description={`Record one from the Kleoth menu bar — meetings appear here from ${meetingsDir()}.`}
        />
      ) : (
        meetings.map((meeting) => <MeetingItem key={meeting.dir} meeting={meeting} />)
      )}
    </List>
  );
}

function MeetingItem({ meeting }: { meeting: Meeting }) {
  const accessories: List.Item.Accessory[] = [{ tag: meeting.tier }];
  if (meeting.startedAt) accessories.push({ date: meeting.startedAt });

  return (
    <List.Item
      icon={Icon.Document}
      title={meeting.title}
      subtitle={meeting.date}
      accessories={accessories}
      actions={
        <ActionPanel>
          <ActionPanel.Section>
            {meeting.hasSummary && <Action.Open title="Open Summary" target={meeting.summaryPath} />}
            {meeting.hasTranscript && <Action.Open title="Open Transcript" target={meeting.transcriptPath} />}
            <Action.ShowInFinder path={meeting.dir} />
          </ActionPanel.Section>
          <ActionPanel.Section>
            {meeting.hasSummary && (
              <Action.CopyToClipboard
                title="Copy Summary"
                content={readText(meeting.summaryPath) ?? ""}
                shortcut={{ modifiers: ["cmd"], key: "c" }}
              />
            )}
            {meeting.hasSummary && (
              <Action.CopyToClipboard
                title="Copy Summary Path"
                content={meeting.summaryPath}
                shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
              />
            )}
            {meeting.hasTranscript && (
              <Action.CopyToClipboard
                title="Copy Transcript Path"
                content={meeting.transcriptPath}
                shortcut={{ modifiers: ["cmd", "opt"], key: "c" }}
              />
            )}
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}
