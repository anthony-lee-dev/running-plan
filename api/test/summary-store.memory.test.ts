import { MemoryActivityStore, MemoryAuthStore, MemorySummaryStore } from "../src/adapters/memory";
import { summaryStoreContract } from "./support/summary-store-contract";

summaryStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const activities = new MemoryActivityStore(auth);
  return { store: new MemorySummaryStore(auth, activities), activities, auth, reset: async () => {} };
});
