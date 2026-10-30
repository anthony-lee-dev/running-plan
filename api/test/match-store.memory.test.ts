import { MemoryActivityStore, MemoryAuthStore, MemoryMatchStore, MemoryPlanStore } from "../src/adapters/memory";
import { matchStoreContract } from "./support/match-store-contract";

matchStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  const activities = new MemoryActivityStore(auth);
  return { store: new MemoryMatchStore(auth, plans, activities), plans, activities, auth, reset: async () => {} };
});
