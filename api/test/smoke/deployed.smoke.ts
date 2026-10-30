// The smoke checks against a deployed API: `npm run smoke -w api` (the production Worker by default), or
// `SMOKE_URL=https://... npm run smoke -w api`. Run it from an up-to-date `main`: it compares the deploy with this
// checkout. Not part of verify: it needs the network.
import { smokeSuite } from "../support/smoke";

// Keep in step with `APIConfiguration.deployedURL` in the iOS app.
const url = process.env.SMOKE_URL || "https://running-plan-api.anthonyhklee.workers.dev";
smokeSuite(url, (request) => fetch(request), url.replace(/\/$/, ""));
