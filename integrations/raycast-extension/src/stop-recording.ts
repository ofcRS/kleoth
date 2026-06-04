import { sendCommand } from "./lib/kleoth";

export default async function Command() {
  await sendCommand("stop", "Kleoth: stopped — transcribing on-device");
}
