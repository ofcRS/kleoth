import { sendCommand } from "./lib/kleoth";

export default async function Command() {
  await sendCommand("toggle", "Kleoth: recording toggled");
}
