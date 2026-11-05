import { MemoryAuthStore, MemoryCheckInStore, MemoryPlanStore, MemorySyncStore } from "../src/adapters/memory";
import { syncStoreContract } from "./support/sync-store-contract";

syncStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  const checkIns = new MemoryCheckInStore(auth, plans);
  return { store: new MemorySyncStore(auth, plans, checkIns), plans, checkIns, auth, reset: async () => {} };
});
