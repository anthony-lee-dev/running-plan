import { memoryDeps } from "../src/adapters/memory";
import { accountExportStoreContract } from "./support/export-store-contract";

accountExportStoreContract("memory", async () => {
  const deps = memoryDeps();
  return {
    store: deps.accountExport,
    auth: deps.auth,
    plans: deps.plans,
    activities: deps.activities,
    matches: deps.matches,
    checkIns: deps.checkIns,
    reset: async () => {},
  };
});
