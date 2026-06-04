import { sendCommand } from "./lib/kleoth";

export default async function Command() {
  await sendCommand("record", "Kleoth: recording started");
}
