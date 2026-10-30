// The contract suite against the app the Node entry serves (`src/node.ts` builds it from `memoryDeps()`; it
// starts a server on import, so the suite builds the same app here).
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import { apiContract } from "./support/api-contract";

apiContract("Node, in-memory", async () => {
  const email = new MemoryEmailSender();
  const app = createApp(memoryDeps({ email }));
  return {
    fetch: async (request) => app.fetch(request),
    lastCode: (to) => email.sent.filter((s) => s.to === to).at(-1)!.code,
    reset: async () => {},
  };
});
