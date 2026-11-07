import { MemoryAuthStore, MemoryCheckInStore, MemoryPlanStore, MemoryProposalStore, MemorySyncStore } from "../src/adapters/memory";
import { syncStoreContract } from "./support/sync-store-contract";

syncStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  const checkIns = new MemoryCheckInStore(auth, plans);
  const proposals = new MemoryProposalStore(auth, plans, checkIns);
  return { store: new MemorySyncStore(auth, plans, checkIns, proposals), plans, checkIns, proposals, auth, reset: async () => {} };
});
