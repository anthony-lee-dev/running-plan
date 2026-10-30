// The smoke checks against a deployed API: `npm run smoke -w api` (the production Worker by default), or
// `SMOKE_URL=https://... npm run smoke -w api`. Not part of verify: it needs the network.
import { smokeSuite } from "../support/smoke";

const url = process.env.SMOKE_URL!;
smokeSuite(url, (request) => fetch(request), url.replace(/\/$/, ""));
