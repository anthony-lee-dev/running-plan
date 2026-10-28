// Node entry with in-memory storage. Keeps the app honest about not depending on Workers.
import { serve } from "@hono/node-server";
import { createApp } from "./app";
import { memoryDeps } from "./adapters/memory";

const port = 8788;
serve({ fetch: createApp(memoryDeps()).fetch, port });
console.log(`api (node, in-memory) on http://localhost:${port}`);
