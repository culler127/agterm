// agterm-opencode-status-plugin
//
// OpenCode lifecycle plugin installed by agterm's Help ▸ Install Agent Status Hooks… command.
// Reports agent status through the installed agterm wrapper; a clean no-op outside agterm.
//
// IMPORTANT: this module must export ONLY plugin function(s). OpenCode's legacy loader treats
// every export as a plugin and throws "Plugin export is not a function" on non-functions.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const ACTIVE = ["active", "--blink"];
const BLOCKED = ["blocked"];
const COMPLETED = ["completed", "--auto-reset"];

function defaultWrapperPath() {
  return join(homedir(), ".config", "agterm", "agent-status", "agterm-agent-status.sh");
}

/**
 * Serialize reports so a slow spawn cannot reorder status.
 * Status reporting is advisory and must never reject into OpenCode's Effect fiber.
 */
function createReportQueue(reportFn) {
  let chain = Promise.resolve();
  return function enqueue(args) {
    if (!args || args.length === 0) return Promise.resolve();
    const pending = chain.then(() => reportFn(args));
    chain = pending.catch(() => {});
    // Swallow rejection on the returned promise too — event may run under Effect.promise.
    return pending.catch(() => {});
  };
}

function spawnReport(wrapper, args) {
  // Wait for the child to exit. Do not time out the wait: resolving early lets the queue start the
  // next report while this wrapper (or agtermctl) is still running, which reorders status under load.
  // A missing wrapper hits 'error' immediately; a healthy status spawn is fast.
  return new Promise((resolve) => {
    const child = spawn(wrapper, args, {
      stdio: "ignore",
      env: process.env,
    });
    child.on("error", () => resolve());
    child.on("close", () => resolve());
  });
}

/**
 * OpenCode plugin entry. Named export — OpenCode loads plugins from ~/.config/opencode/plugins/.
 * This must remain the only export from this file.
 *
 * Keeps two Sets (same shape as OpenCode's own status notifications plugin):
 * - `active`: sessionIDs that have seen busy/retry — idle is ignored until then, so a subagent's
 *   idle cannot paint completed onto a still-working parent pane.
 * - `errored`: sessionIDs that hit session.error — the following session.status(idle) that
 *   SessionProcessor.halt always publishes is swallowed so blocked is not overwritten by completed.
 */
export const AgtermStatusPlugin = async () => {
  if (!process.env.AGTERM_SESSION_ID) {
    return {};
  }

  const wrapper = process.env.AGTERM_STATUS_WRAPPER || defaultWrapperPath();
  const enqueue = createReportQueue((args) => spawnReport(wrapper, args));
  const active = new Set();
  const errored = new Set();

  function mapEventToArgs(event) {
    const type = event?.type;
    const properties = event?.properties ?? {};
    const sessionID =
      typeof properties.sessionID === "string" && properties.sessionID
        ? properties.sessionID
        : undefined;

    switch (type) {
      case "session.status": {
        const kind =
          typeof properties.status === "string" ? properties.status : properties.status?.type;
        if (typeof kind !== "string") return null;
        switch (kind.toLowerCase()) {
          case "busy":
          case "retry":
            if (sessionID) {
              active.add(sessionID);
              errored.delete(sessionID);
            }
            return ACTIVE;
          case "idle":
            // Ignore idle with no preceding busy/retry for this sessionID (covers subagent idle and
            // an idle published with no matching busy).
            if (!sessionID || !active.has(sessionID)) return null;
            active.delete(sessionID);
            if (errored.has(sessionID)) {
              errored.delete(sessionID);
              return null;
            }
            return COMPLETED;
          default:
            return null;
        }
      }
      case "permission.asked":
      case "question.asked":
        return BLOCKED;
      case "session.error":
        // Latch only for a session we have seen busy; halt always follows with status(idle).
        if (!sessionID || !active.has(sessionID)) return null;
        errored.add(sessionID);
        return BLOCKED;
      // Clear blocked after the user answers; session.status(busy) may lag behind the reply.
      case "permission.replied":
      case "question.replied":
      case "question.rejected":
        return ACTIVE;
      // deprecated: OpenCode also emits session.status(type=idle); handling both would double-fire completed
      case "session.idle":
        return null;
      default:
        return null;
    }
  }

  return {
    event: async ({ event }) => {
      const args = mapEventToArgs(event);
      if (args) await enqueue(args);
    },
  };
};
