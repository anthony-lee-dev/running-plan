import { MemoryAuthStore, MemoryPlanStore } from "../src/adapters/memory";
import { planStoreContract } from "./support/plan-store-contract";

planStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  return { store: new MemoryPlanStore(auth), auth, reset: async () => {} };
});
