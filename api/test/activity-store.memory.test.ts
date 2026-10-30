import { MemoryActivityStore, MemoryAuthStore } from "../src/adapters/memory";
import { activityStoreContract } from "./support/activity-store-contract";

activityStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  return { store: new MemoryActivityStore(auth), auth, reset: async () => {} };
});
