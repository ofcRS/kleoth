// bun test marketing/ — the release gate's command parser.
import { describe, expect, test } from "bun:test";
import { releaseCommand } from "./sync.ts";

describe("releaseCommand: blocks what tags or publishes a release", () => {
  const cases: [string, string | null][] = [
    ["git tag v0.5.0", "0.5.0"],
    ["git tag -a v0.5.0 -m \"Kleoth 0.5.0\"", "0.5.0"],
    ["git status && git tag v0.5.0", "0.5.0"],
    ["cd app; git tag -s v0.5.0", "0.5.0"],
    ["git -C /repo tag v0.5.0", "0.5.0"],
    ["git -c user.name=x tag -a v0.5.0 -m x", "0.5.0"],
    ["git --no-pager tag v0.5.0", "0.5.0"],
    ["(git tag v0.5.0)", "0.5.0"],
    ["command git tag v0.5.0", "0.5.0"],
    ["env GIT_AUTHOR_NAME=x git tag v0.5.0", "0.5.0"],
    ["FOO=1 git tag v0.5.0", "0.5.0"],
    ["git tag -m 'fix -d flag' v0.5.0", "0.5.0"],
    ["git tag -a v0.5.0 -m \"notes for v0.4.9\"", "0.5.0"],
    ["git tag \"v0.5.0\"", "0.5.0"],
    ["gh release create v0.5.0 app/dist/Kleoth-0.5.0.dmg", "0.5.0"],
    ["gh -R ofcRS/kleoth release create v0.5.0", "0.5.0"],
    ["gh release create --repo ofcRS/kleoth v0.5.0", "0.5.0"],
    ["gh release create", null], // no version named → the gate uses Info.plist
  ];
  for (const [command, version] of cases) {
    test(command, () => expect(releaseCommand(command)).toEqual({ version }));
  }
});

describe("releaseCommand: lets everything else through", () => {
  for (const command of [
    "ls -la",
    "git tag",
    "git tag -l",
    "git tag -l 'v0.*'",
    "git tag --list",
    "git tag -n",
    "git tag -d v0.4.0",
    "git tag --delete v0.4.0",
    "git tag -v v0.4.0",
    "git tag --contains HEAD",
    "git log --tags --oneline",
    "echo git tag v0.5.0",
    "gh release view v0.4.0",
    "gh release list",
    "git commit -m \"docs: how git tag v0.5.0 is gated\"",
  ]) {
    test(command, () => expect(releaseCommand(command)).toBeNull());
  }
});
