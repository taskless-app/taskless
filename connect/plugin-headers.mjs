import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const home = process.env.HOME || process.env.USERPROFILE || homedir();
const windows = process.platform === "win32";
const helper = join(home, ".config", "taskless", windows ? "mcp-headers.ps1" : "mcp-headers");

if (!existsSync(helper)) {
  process.stdout.write("{}\n");
} else {
  const result = windows
    ? spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", helper], { stdio: ["ignore", "inherit", "inherit"], windowsHide: true })
    : spawnSync("sh", [helper], { stdio: ["ignore", "inherit", "inherit"] });
  if (result.error) process.stdout.write("{}\n");
  else process.exitCode = result.status ?? 1;
}
