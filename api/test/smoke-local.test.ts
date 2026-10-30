// The smoke checks against the app in-process, so they are known to pass on `main` before they judge a deploy.
import { createApp } from "../src/app";
import { memoryDeps } from "../src/adapters/memory";
import { smokeSuite } from "./support/smoke";

const app = createApp(memoryDeps());
smokeSuite("in-process", (request) => app.fetch(request));
